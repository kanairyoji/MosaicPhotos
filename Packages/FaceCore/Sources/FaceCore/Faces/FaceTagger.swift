import PerceptionCore
import Foundation
import MosaicSupport

/// 未スキャンの写真に対して顔検出＋埋め込み＋クラスタリングをバックグラウンドで増分実行する。
/// CLIP の `PhotoTagger` と同じく**小バッチ＋休止＋譲り**で trickle 処理し、端末・UI を圧迫しない。
@MainActor
final class FaceTagger {
    private let store: FaceStore
    private let provider: FacePerceptionProvider?
    /// 実行中フラグ（force 差し替え時に PeopleEngine が旧タスクの終了を待つため read 可能にする）。
    private(set) var isRunning = false
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "FaceTagger")

    init(store: FaceStore, provider: FacePerceptionProvider?) {
        self.store = store
        self.provider = provider
    }

    /// `candidateRefKeys`（端末写真の refKey 群）のうち未スキャン分を処理する。
    /// 進捗ごと・完了時に `onBatch` を呼ぶ（ピープル一覧の再読込に使う）。
    /// ⚠️ 既定値は**夜間ウィンドウ向け**（実機 diagnostics-72）。スキャンは前面では始めない
    /// （`startScan` が `isAppActive` で弾く）ので、ここで長く眠る相手はもう居ない。
    /// 旧値（8 枚ごとに 2.5 秒休止）は 5 分の窓のうち **87 秒を睡眠に使っていた**——
    /// 実作業は 1 枚 80ms で、280 枚＝22 秒しか進んでいなかった。
    /// 譲りは `shouldPause` が**1 枚ごと**に見るので、休止を短くしても応答性は落ちない。
    /// バッチを 16 に上げるのは、クラウド写真のサムネ往復（1 回 約 870ms）を半分に減らすため。
    func scan(candidateRefKeys: [String],
              batchSize: Int = 16,
              betweenBatchNs: UInt64 = 500_000_000,
              allowSimulator: Bool = false,
              shouldPause: @MainActor () -> Bool = { false },
              networkAllowed: @MainActor () -> Bool = { true },
              onProgress: @MainActor (Int) -> Void = { _ in },
              onBatch: () async -> Void) async {
        guard let provider, provider.isAvailable else {
            Self.log.info("face scan: skipped — face model not bundled / provider unavailable")
            Diagnostics.mark("faces: skipped — model not bundled/unavailable")
            return
        }
        // 顔モデルはシミュレータでは cpuOnly で重いため既定でスキップ（実機で計測）。
        // ただし Developer Options のデバッグトグル（allowSimulator）が ON なら走らせる。
        #if targetEnvironment(simulator)
        if !allowSimulator {
            Self.log.info("face scan: skipped on simulator (enable in Developer Options to debug)")
            Diagnostics.mark("faces: skipped on simulator — enable 'Face scan in Simulator' to run")
            return
        }
        Diagnostics.mark("faces: running on simulator (debug, cpuOnly = slow)")
        #endif
        guard !isRunning else {
            Diagnostics.mark("faces: tagger.scan skip — isRunning=true (old task not finished)")
            return
        }
        isRunning = true
        defer { isRunning = false; onProgress(0) }

        let done = await store.scannedRefKeys()
        // ローカル("L-")を必ず先に、クラウド("C-")は後回し（母数が巨大で細切れ窓では終わらないため）。
        // 回線が許可されない（例: Wi-Fi 待ち）ときはクラウド分を今回は対象から外す＝端末内写真だけ
        // 進める（Wi-Fi 復帰時の次回スキャンでクラウドを拾う。顔検出はキャッシュ済みサムネDLを要する）。
        let cloudOK = networkAllowed()
        let localTodo = candidateRefKeys.filter { $0.hasPrefix("L-") && !done.contains($0) }
        let cloudTodo = cloudOK ? candidateRefKeys.filter { $0.hasPrefix("C-") && !done.contains($0) } : []
        let todo = localTodo + cloudTodo
        Diagnostics.mark("faces: start — candidates=\(candidateRefKeys.count) already=\(done.count) "
                         + "todo=\(todo.count) (local=\(localTodo.count) cloud=\(cloudTodo.count)\(cloudOK ? "" : " deferred:no-wifi"))")
        guard !todo.isEmpty else {
            Diagnostics.mark("faces: nothing to scan (all done)")
            return
        }
        Self.log.info("face scan: start — \(todo.count) photos to scan (batch \(batchSize))")
        onProgress(todo.count)

        var index = 0
        var processed = 0
        var facesFound = 0
        // ⚠️ 停止判定は 1 枚単位（検出+埋め込みは 1 枚数百 ms〜。バッチ一括だと
        // ロック解除直後の譲りが遅れる）。保存はバッチ 1 回（T3）を維持。
        await BackgroundTrickle.run(
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            pausePerfLabel: "face.pauseWait",   // センサー: 譲り待ちの発生数
            unitPerfLabel: "face.photoMs",
            // クラウド分のサムネをバッチごとに一括先行取得する（ADR-83）。
            warmBatch: { [provider] batch in provider.warmUp(refKeys: batch) },
            nextBatch: { _ in
                let end = min(index + batchSize, todo.count)
                defer { index = end }
                // ⚠️ **次のバッチ**の素材も今から取り始める（ADR-83 追記）。推論は ANE ゲートで
                // 直列＝1 バッチ約 1.6 秒かかるので、その裏で次バッチのダウンロード（約 0.8 秒）を
                // 完全に隠せる。これが無いとバッチの先頭で毎回ダウンロード待ちが露出する。
                let aheadEnd = min(end + batchSize, todo.count)
                if end < aheadEnd { provider.warmUp(refKeys: Array(todo[end..<aheadEnd])) }
                return Array(todo[index..<end])
            },
            processUnit: { refKey -> (refKey: String, faces: [DetectedFaceSignal])? in
                // ANE 直列化ゲート（diagnostics-19）は **provider 側（FacePerceptionAdapter）の内側**で
                // 取る。ここで包むと画像ロードまでゲートに入り、その間ほかの解析が全部止まるため
                // （ADR-73）。ここでは包まないこと＝包むと入れ子になる。
                let one = await provider.detectFaces(refKeys: [refKey])
                // ⚠️ dict に**キーが無い**＝画像を取得できず解析していない（ADR-92）。
                // これを「顔ゼロで走査済み」として記録すると、版を上げるまで二度と見直されない。
                // 閲覧中の譲り・回線・バッチ失敗はいずれも一時的なので、記録せず次の窓へ回す。
                // 解析できた場合は顔ゼロ（空配列）でも記録する＝再スキャンしない。
                guard let faces = one[refKey] else { return nil }
                return (refKey: refKey, faces: faces)
            },
            commitBatch: { batchIndex, batch, results in
                // 解析できた写真だけを記録する（nil＝画像が取れず未解析なので記録しない）。
                let records = results.compactMap { $0 }
                guard !records.isEmpty else {
                    // 全件が未解析（例: 閲覧中でずっと譲った）。バッチ自体は進めて次へ。
                    return batch.isEmpty ? .stop : .proceed
                }
                facesFound += records.reduce(0) { $0 + $1.faces.count }
                await store.recordScans(records)   // T3: save はバッチ 1 回
                processed += batch.count
                AnalysisActivity.recordActivity(.faces)
                onProgress(max(0, todo.count - processed))

                if (batchIndex + 1) % 8 == 0 {
                    Diagnostics.mark("faces: \(processed)/\(todo.count) scanned, faces=\(facesFound)")
                    await onBatch()   // 一覧をときどき更新
                }
                return .proceed
            })
        Self.log.info("face scan: finished — \(processed) photos")
        Diagnostics.mark("faces: finished — scanned=\(processed) faces=\(facesFound)")
        await onBatch()
    }
}
