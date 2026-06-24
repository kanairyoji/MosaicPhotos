import Foundation
import MosaicSupport

/// 未埋め込みの写真（ローカル/クラウド）へ CLIP 画像埋め込みをバックグラウンドで増分付与する。
/// メタデータ生成をブロックしないよう、生成後に fire-and-forget で呼ぶ。重複起動は防ぐ。
@MainActor
final class PhotoTagger {
    private let store: AutoAlbumStore
    private let perception: PhotoPerceptionProvider?
    private var isTagging = false
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Tagger")

    init(store: AutoAlbumStore, perception: PhotoPerceptionProvider?) {
        self.store = store
        self.perception = perception
    }

    /// 未埋め込み写真を**小バッチ＋バッチ間スリープ**で穏やかに処理する（バックグラウンドで
    /// 端末・UI を圧迫しないため）。クラウドは1件ごとにサムネDL＋CLIP が走り重いので、意図的に
    /// ゆっくり trickle させる。バッチ進行ごと（と完了時）に `onBatch` を呼ぶ。
    func embedUnprocessed(batchSize: Int = 8,
                          betweenBatchNs: UInt64 = 2_500_000_000,   // 2.5s
                          maxBatches: Int = 20_000,
                          onBatch: () async -> Void) async {
        guard let perception else {
            Self.log.info("embed: skipped — no perception provider injected")
            return
        }
        guard !isTagging else {
            Self.log.info("embed: skipped — already running")
            return
        }
        isTagging = true
        defer { isTagging = false }

        let pending = await store.unembeddedCount()
        Self.log.info("embed: start — \(pending) photos pending (batchSize \(batchSize), throttled)")
        let startedAt = Date()

        var processed = 0
        for batch in 0..<maxBatches {
            if Task.isCancelled { break }
            let refKeys = await store.unembeddedRefKeys(limit: batchSize)
            guard !refKeys.isEmpty else {
                Self.log.info("embed: no more unembedded photos — stopping at batch \(batch)")
                break
            }
            let batchStart = Date()
            let signals = await perception.perceive(refKeys: refKeys)
            // perceive が返さなかった refKey も「処理済み」にして無限ループを防ぐ。
            var merged = signals
            for key in refKeys where merged[key] == nil { merged[key] = PhotoPerception() }
            await store.applyPerception(merged)
            processed += refKeys.count

            let withVector = signals.values.filter { $0.clipVector != nil }.count
            let secs = String(format: "%.1f", Date().timeIntervalSince(batchStart))
            Self.log.info("embed: batch \(batch) done — \(refKeys.count) photos in \(secs)s "
                          + "(\(withVector) with CLIP vector); total \(processed)")

            if batch % 16 == 15 { await onBatch() }
            // ★ バッチ間で休む：端末・ネットワーク・UI を圧迫しないよう trickle 処理にする。
            try? await Task.sleep(nanoseconds: betweenBatchNs)
        }
        let total = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        Self.log.info("embed: finished — \(processed) photos in \(total)s")
        await onBatch()
    }
}
