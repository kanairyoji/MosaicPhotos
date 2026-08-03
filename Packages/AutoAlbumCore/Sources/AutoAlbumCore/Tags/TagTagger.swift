import PerceptionCore
import Foundation
import MosaicSupport

/// 写真 1 枚から Vision 一括パスで取得する付帯情報（photo-info-expansion）。
/// タグ（シーン分類＋動物＋アセット種別）・OCR テキスト・人物数・美的スコアをまとめて持つ。
public struct PhotoSenseInfo: Sendable, Equatable {
    /// シーンタグ（Vision 分類・precision 0.9 フィルタ）＋動物種別（VNRecognizeAnimals）＋
    /// アセット種別タグ（screenshot / panorama / live photo 等・ローカルのみ）。英語・小文字。
    public var tags: [String]
    /// 写真内テキスト（OCR・`VNRecognizeTextRequest`）。検出なしは nil。
    public var ocrText: String?
    /// 写っている人物の数（`VNDetectHumanRectanglesRequest`・上半身検出）。未計測は nil。
    public var humanCount: Int?
    /// 美的スコア（`VNCalculateImageAestheticsScores`・-1〜1・iOS 18+）。未計測は nil。
    public var aesthetic: Double?

    public init(tags: [String] = [], ocrText: String? = nil,
                humanCount: Int? = nil, aesthetic: Double? = nil) {
        self.tags = tags
        self.ocrText = ocrText
        self.humanCount = humanCount
        self.aesthetic = aesthetic
    }
}

/// シーンタグ等（Vision 一括パス）とキャプション（VLM）の知覚 seam。実体はアプリ側（MobileCLIPKit）。
public protocol TagPerceptionProvider: Sendable {
    /// Vision 分類が使えるか（分類は OS 内蔵なので通常 true）。
    var isTaggingAvailable: Bool { get }
    /// refKey 群 → 付帯情報（タグ・OCR・人数・美的スコアを 1 回の Vision パスで）。
    /// 取得不可の写真は空 info（「処理済み」として記録し無限ループを防ぐ）。
    func senseInfo(refKeys: [String]) async -> [String: PhotoSenseInfo]
    /// VLM キャプションが使えるか（モデル同梱時のみ true）。
    var isCaptioningAvailable: Bool { get }
    /// refKey 群 → 短文キャプション（英語）。取得不可の写真は結果に含めない。
    func captions(refKeys: [String]) async -> [String: String]
    /// キャプション用の重いモデル（VLM≈877MB）がロード済みなら解放する（1-d）。
    /// キャプションフェーズ完了後に呼び、CLIP 画像塔・facenet と同時常駐しないようにする。既定は無処理。
    func releaseCaptionModelIfLoaded()
}

public extension TagPerceptionProvider {
    func releaseCaptionModelIfLoaded() {}
}

/// タグ・キャプションの夜間トリクル付与（FaceTagger と同パターン）。
/// 重い処理の共通方針（電源＋アイドル・BackgroundYield）はバッチごとに確認する。
@MainActor
final class TagTagger {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Tags")
    private let store: TagStore
    private let provider: TagPerceptionProvider?
    private(set) var isRunning = false

    init(store: TagStore, provider: TagPerceptionProvider?) {
        self.store = store
        self.provider = provider
    }

    /// VLM キャプションが利用可能か（モデル同梱時のみ true）。フル画像の「生成中」表示に使う。
    var isCaptioningAvailable: Bool { provider?.isCaptioningAvailable ?? false }

    /// キャプションモデル（VLM）を解放する（1-d・キャプションフェーズ完了後に呼ぶ）。
    func releaseCaptionModel() { provider?.releaseCaptionModelIfLoaded() }

    /// 未タグ写真にシーンタグを付ける（バッチ 8・save はバッチ 1 回）。
    /// Vision 分類は CPU/ANE で軽い（数十 ms/枚）ため CLIP 埋め込みより速く全量に行き渡る。
    func tagUnprocessed(candidateRefKeys: [String],
                        batchSize: Int = 8,
                        betweenBatchNs: UInt64 = 500_000_000,
                        shouldPause: @MainActor () -> Bool = { false },
                        onProgress: @MainActor (Int) -> Void = { _ in }) async {
        guard let provider, provider.isTaggingAvailable else { return }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; onProgress(0) }

        let already = await store.taggedRefKeys()
        let todo = candidateRefKeys.filter { !already.contains($0) }
        guard !todo.isEmpty else { return }
        Diagnostics.mark("tags: start — \(todo.count) photos to tag")

        var index = 0
        var processed = 0
        // 候補C: 「単位」を **4 枚ミニバッチ**にし、senseInfo 内でロード＋Vision 一括パスを並列化する。
        // 停止判定はミニバッチ単位だが、内部が並列なので実時間は 1 枚相当＝譲り応答性はほぼ維持。
        // 保存はバッチ 1 回。
        let miniBatchSize = 4
        await BackgroundTrickle.run(
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            unitPerfLabel: "tags.photoMs",
            unitPerfDivisor: { (chunk: [String]) in Double(max(1, chunk.count)) },   // 1 枚あたり ms
            nextBatch: { _ in
                let end = min(index + batchSize, todo.count)
                defer { index = end }
                let batch = Array(todo[index..<end])
                return stride(from: 0, to: batch.count, by: miniBatchSize).map {
                    Array(batch[$0..<min($0 + miniBatchSize, batch.count)])
                }
            },
            processUnit: { (chunk: [String]) in
                // ANE 直列化ゲート（顔検出と Vision タグを同時に ANE で走らせない・diagnostics-19 対策）。
                let dict = await MLInferenceGate.shared.run { await provider.senseInfo(refKeys: chunk) }
                return chunk.map { (refKey: $0, info: dict[$0] ?? PhotoSenseInfo()) }
            },
            commitBatch: { _, _, results in
                let flat = results.flatMap { $0 }
                guard !flat.isEmpty else { return .stop }
                await store.recordTags(flat)
                let before = processed
                processed += flat.count
                AnalysisActivity.recordActivity(.sceneTags)
                onProgress(max(0, todo.count - processed))
                if processed / 256 != before / 256 {
                    Diagnostics.mark("tags: \(processed)/\(todo.count) tagged")
                }
                return .proceed
            })
        Diagnostics.mark("tags: finished — \(processed) tagged")
    }

    /// タグ済み・キャプション未生成の写真に VLM キャプションを付ける（1 枚 1〜2 秒・数晩がかり）。
    /// `favoritesNewestFirst` はお気に入り（キャプション対象）を**撮影日降順**に並べた列で、
    /// この順に処理する＝新しい写真から先に説明が付く（全解析パス共通の方針）。
    func captionUnprocessed(batchSize: Int = 4,
                            betweenBatchNs: UInt64 = 1_000_000_000,
                            maxBatches: Int = .max,
                            favoritesNewestFirst: [String]? = nil,
                            shouldPause: @MainActor () -> Bool = { false }) async {
        guard let provider, provider.isCaptioningAvailable else { return }
        // お気に入り限定でその集合が空なら、付ける対象が無いので即終了（毎回の空クエリを避ける）。
        if let favoritesNewestFirst, favoritesNewestFirst.isEmpty { return }
        #if targetEnvironment(simulator)
        // VLM は cpuOnly で 1 枚十数秒かかり検証の妨げになるため、シミュレータでは実行しない。
        Diagnostics.mark("captions: skipped on simulator (VLM runs cpuOnly here)")
        return
        #endif
        // 未生成（タグ済みレコードのみ）を新しい順の静的キューにする。実行中の新規写真は次回巡回で拾う。
        let pending = await store.captionPendingSet(favorites: favoritesNewestFirst.map(Set.init))
        var queue: [String] = favoritesNewestFirst.map { $0.filter(pending.contains) }
            ?? pending.sorted()
        guard !queue.isEmpty else { return }
        var processed = 0
        // 停止判定は 1 枚単位（VLM は 1 枚 1〜2 秒＝バッチ一括だと譲りが数秒遅れる）。
        await BackgroundTrickle.run(
            maxBatches: maxBatches,
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            unitPerfLabel: "caption.photoMs",
            nextBatch: { _ in
                let batch = Array(queue.prefix(batchSize))
                queue.removeFirst(batch.count)
                return batch
            },
            processUnit: { refKey in
                // ANE 直列化ゲート（VLM キャプションと顔検出/CLIP を同時に ANE で走らせない・diagnostics-19 対策）。
                let one = await MLInferenceGate.shared.run { await provider.captions(refKeys: [refKey]) }
                // 取得できなかった写真も空で記録して無限ループを防ぐ。
                return (refKey: refKey, caption: one[refKey] ?? "")
            },
            commitBatch: { _, _, results in
                guard !results.isEmpty else { return .stop }
                await store.recordCaptions(results)
                processed += results.count
                AnalysisActivity.recordActivity(.captions)
                if processed % 64 == 0 { Diagnostics.mark("captions: \(processed) done") }
                return .proceed
            })
        if processed > 0 { Diagnostics.mark("captions: finished — \(processed)") }
    }
}
