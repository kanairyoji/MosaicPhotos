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
                          shouldPause: @MainActor () -> Bool = { false },
                          networkAllowed: @MainActor () -> Bool = { true },
                          onProgress: @MainActor (Int) -> Void = { _ in },
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
        defer { isTagging = false; onProgress(0) }

        let pending = await store.unembeddedCount()
        Self.log.info("embed: start — \(pending) photos pending (batchSize \(batchSize), throttled)")
        onProgress(pending)
        let startedAt = Date()

        var processed = 0
        for batch in 0..<maxBatches {
            if Task.isCancelled { break }
            // ★ ユーザー操作中（スクラブ等）は重い知覚（サムネDL＋CLIP）を譲り、落ち着くまで待つ（G）。
            while shouldPause() && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)   // 0.3s
            }
            if Task.isCancelled { break }
            // 回線NG（例: Wi-Fi 待ち）のときはクラウド写真（サムネDL）をスキップし、
            // ローカル写真だけ進める（スマート方針 b）。Wi-Fi 復帰でクラウド分が再開される。
            let netOK = networkAllowed()
            let refKeys = await store.unembeddedRefKeys(limit: batchSize, localOnly: !netOK)
            guard !refKeys.isEmpty else {
                // ローカルが尽きた。回線NGで残り（クラウド分）があれば「保留」、無ければ「完了」。
                // どちらも終了し、回線/電源の復帰時にアプリ側が再起動する（isTagging を抱え続けない）。
                if !netOK {
                    let deferredCloud = await store.unembeddedCount()
                    Self.log.info(deferredCloud > 0
                        ? "embed: local done; \(deferredCloud) cloud photos deferred (no Wi-Fi)"
                        : "embed: no more unembedded photos — stopping at batch \(batch)")
                } else {
                    Self.log.info("embed: no more unembedded photos — stopping at batch \(batch)")
                }
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

            onProgress(max(0, pending - processed))
            // AI 再検索（onBatch）は全件 fetch＋採点で footprint がスパイクする（~200→400MB）。
            // 背景再埋め込み中は周期を粗くしてスパイク頻度を下げ、メモリ圧迫イベントを減らす
            // （圧迫が減るとサムネのメモリ保持も安定する）。最終結果は完了時の onBatch で必ず反映。
            if batch % 48 == 47 { await onBatch() }
            // ★ バッチ間で休む：端末・ネットワーク・UI を圧迫しないよう trickle 処理にする。
            try? await Task.sleep(nanoseconds: betweenBatchNs)
        }
        let total = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        Self.log.info("embed: finished — \(processed) photos in \(total)s")
        await onBatch()
    }
}
