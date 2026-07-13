import Foundation
import MosaicSupport

/// シーンタグ（Vision 分類）とキャプション（VLM）の知覚 seam。実体はアプリ側（MobileCLIPKit）。
public protocol TagPerceptionProvider: Sendable {
    /// Vision 分類が使えるか（分類は OS 内蔵なので通常 true）。
    var isTaggingAvailable: Bool { get }
    /// refKey 群 → シーンタグ（英語識別子・precision フィルタ済み）。取得不可の写真は空配列。
    func sceneTags(refKeys: [String]) async -> [String: [String]]
    /// VLM キャプションが使えるか（モデル同梱時のみ true）。
    var isCaptioningAvailable: Bool { get }
    /// refKey 群 → 短文キャプション（英語）。取得不可の写真は結果に含めない。
    func captions(refKeys: [String]) async -> [String: String]
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
        // ⚠️ 停止判定は 1 枚単位（クラウド写真はネット取得込みで 1 枚数秒かかり得るため、
        // バッチ一括だと譲りが数十秒遅れる＝ロック解除直後の操作が重くなる）。保存はバッチ 1 回。
        await BackgroundTrickle.run(
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            unitPerfLabel: "tags.photoMs",
            nextBatch: { _ in
                let end = min(index + batchSize, todo.count)
                defer { index = end }
                return Array(todo[index..<end])
            },
            processUnit: { refKey in
                let one = await provider.sceneTags(refKeys: [refKey])
                return (refKey: refKey, tags: one[refKey] ?? [])
            },
            commitBatch: { _, _, results in
                guard !results.isEmpty else { return .stop }
                await store.recordTags(results)
                processed += results.count
                AnalysisActivity.recordActivity(.sceneTags)
                onProgress(max(0, todo.count - processed))
                if processed % 256 == 0 {
                    Diagnostics.mark("tags: \(processed)/\(todo.count) tagged")
                }
                return .proceed
            })
        Diagnostics.mark("tags: finished — \(processed) tagged")
    }

    /// タグ済み・キャプション未生成の写真に VLM キャプションを付ける（1 枚 1〜2 秒・数晩がかり）。
    /// `favorites` 指定時はその集合（お気に入り）のみを対象にする（重い文章生成をお気に入り限定に絞る）。
    func captionUnprocessed(batchSize: Int = 4,
                            betweenBatchNs: UInt64 = 1_000_000_000,
                            maxBatches: Int = .max,
                            favorites: Set<String>? = nil,
                            shouldPause: @MainActor () -> Bool = { false }) async {
        guard let provider, provider.isCaptioningAvailable else { return }
        // お気に入り限定でその集合が空なら、付ける対象が無いので即終了（毎回の空クエリを避ける）。
        if let favorites, favorites.isEmpty { return }
        #if targetEnvironment(simulator)
        // VLM は cpuOnly で 1 枚十数秒かかり検証の妨げになるため、シミュレータでは実行しない。
        Diagnostics.mark("captions: skipped on simulator (VLM runs cpuOnly here)")
        return
        #endif
        var processed = 0
        // 停止判定は 1 枚単位（VLM は 1 枚 1〜2 秒＝バッチ一括だと譲りが数秒遅れる）。
        // todo は静的な差分でなく「キャプション未生成」の動的クエリで都度供給する。
        await BackgroundTrickle.run(
            maxBatches: maxBatches,
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            unitPerfLabel: "caption.photoMs",
            nextBatch: { _ in await store.captionPending(limit: batchSize, favorites: favorites) },
            processUnit: { refKey in
                let one = await provider.captions(refKeys: [refKey])
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
