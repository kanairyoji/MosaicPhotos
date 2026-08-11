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

/// シーンタグ等（Vision 一括パス）の知覚 seam。実体はアプリ側（MobileCLIPKit）。
/// ※ VLM キャプション seam は廃止（ADR-108・検索寄与ゼロの実測＝台帳 S13）。
public protocol TagPerceptionProvider: Sendable {
    /// Vision 分類が使えるか（分類は OS 内蔵なので通常 true）。
    var isTaggingAvailable: Bool { get }
    /// refKey 群 → 付帯情報（タグ・OCR・人数・美的スコアを 1 回の Vision パスで）。
    /// 取得不可の写真は空 info（「処理済み」として記録し無限ループを防ぐ）。
    func senseInfo(refKeys: [String]) async -> [String: PhotoSenseInfo]
    /// これから処理する refKey 群の素材を**先に取りに行く**ヒント（ADR-83）。**即座に返る**こと。
    func warmUp(refKeys: [String])
}

public extension TagPerceptionProvider {
    func warmUp(refKeys: [String]) {}
}

/// シーンタグの夜間トリクル付与（FaceTagger と同パターン）。
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

    /// 未タグ写真にシーンタグを付ける（バッチ 8・save はバッチ 1 回）。
    /// Vision 分類は CPU/ANE で軽い（数十 ms/枚）ため CLIP 埋め込みより速く全量に行き渡る。
    /// - Parameter maxBatches: 1 回の呼び出しで処理するバッチ数の上限（ADR-85）。
    ///   既定は無制限だが、背景実行では上限を設けて CLIP 埋め込み・キャプションへ順番を回す。
    func tagUnprocessed(candidateRefKeys: [String],
                        batchSize: Int = 8,
                        betweenBatchNs: UInt64 = 500_000_000,
                        maxBatches: Int = .max,
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
            maxBatches: maxBatches,
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            unitPerfLabel: "tags.photoMs",
            unitPerfDivisor: { (chunk: [String]) in Double(max(1, chunk.count)) },   // 1 枚あたり ms
            // クラウド分のサムネをバッチごとに一括先行取得する（ADR-83）。
            warmBatch: { [provider] chunks in provider.warmUp(refKeys: chunks.flatMap { $0 }) },
            nextBatch: { _ in
                let end = min(index + batchSize, todo.count)
                defer { index = end }
                // 次バッチの素材も今から取り始める（ADR-83 追記）＝現バッチの推論と重ねる。
                let aheadEnd = min(end + batchSize, todo.count)
                if end < aheadEnd { provider.warmUp(refKeys: Array(todo[end..<aheadEnd])) }
                let batch = Array(todo[index..<end])
                return stride(from: 0, to: batch.count, by: miniBatchSize).map {
                    Array(batch[$0..<min($0 + miniBatchSize, batch.count)])
                }
            },
            processUnit: { (chunk: [String]) in
                // ANE 直列化ゲート（diagnostics-19）は **provider 側（VisionTagAdapter.sense）の内側**で
                // 取る（ADR-73）。ここで包むと (a) 画像ロードまでゲートに入り、(b) senseInfo 内部の
                // 3 並列がゲートの内側で走って「同時に 1 つ」を自ら破る。ここでは包まないこと。
                let dict = await provider.senseInfo(refKeys: chunk)
                // ⚠️ 辞書に**無い** refKey は「中断されて手を付けなかった」写真なので記録しない
                //    （ADR-98）。以前は `?? PhotoSenseInfo()` で空を埋めており、中断した写真まで
                //    「タグ付け済み」として保存され、次の窓で二度と拾われなくなっていた（ADR-92 の罠）。
                //    取得**不能**な写真は provider が空 info を辞書に載せて返すので、ここで残る
                //    ＝無限リトライにはならない。
                return chunk.compactMap { key in dict[key].map { (refKey: key, info: $0) } }
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
        // 残数も出す（上限で打ち切ったのか、本当に終わったのかをログだけで区別するため・ADR-85）。
        Diagnostics.mark("tags: finished — \(processed) tagged (remaining=\(max(0, todo.count - processed)))")
    }

}
