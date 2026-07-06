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
        while index < todo.count, !Task.isCancelled {
            while shouldPause() && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { break }

            let end = min(index + batchSize, todo.count)
            let batch = Array(todo[index..<end])
            index = end

            let tBatch = PerfTrace.nowNs()
            let results = await provider.sceneTags(refKeys: batch)
            PerfTrace.count("tags.batchMs", value: PerfTrace.msSince(tBatch))
            await store.recordTags(batch.map { ($0, results[$0] ?? []) })
            processed += batch.count
            onProgress(max(0, todo.count - processed))
            if processed % 256 == 0 {
                Diagnostics.mark("tags: \(processed)/\(todo.count) tagged")
            }
            try? await Task.sleep(nanoseconds: betweenBatchNs)
        }
        Diagnostics.mark("tags: finished — \(processed) tagged")
    }

    /// タグ済み・キャプション未生成の写真に VLM キャプションを付ける（1 枚 1〜2 秒・数晩がかり）。
    func captionUnprocessed(batchSize: Int = 4,
                            betweenBatchNs: UInt64 = 1_000_000_000,
                            shouldPause: @MainActor () -> Bool = { false }) async {
        guard let provider, provider.isCaptioningAvailable else { return }
        var processed = 0
        while !Task.isCancelled {
            while shouldPause() && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { break }
            let batch = await store.captionPending(limit: batchSize)
            guard !batch.isEmpty else { break }
            let tBatch = PerfTrace.nowNs()
            let results = await provider.captions(refKeys: batch)
            PerfTrace.count("caption.batchMs", value: PerfTrace.msSince(tBatch))
            // 取得できなかった写真も空で記録して無限ループを防ぐ。
            await store.recordCaptions(batch.map { ($0, results[$0] ?? "") })
            processed += batch.count
            if processed % 64 == 0 { Diagnostics.mark("captions: \(processed) done") }
            try? await Task.sleep(nanoseconds: betweenBatchNs)
        }
        if processed > 0 { Diagnostics.mark("captions: finished — \(processed)") }
    }
}
