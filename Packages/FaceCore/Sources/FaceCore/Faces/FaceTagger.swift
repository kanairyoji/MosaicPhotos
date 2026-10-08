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

    /// 連続でこの回数、1 枚も解析できなければ今回のスキャンを畳む（次の窓に回す）。
    /// 3 バッチ＝48 枚ぶん空振りすれば、原因（譲り・回線・取得失敗）は続いていると見てよい。
    static let maxEmptyBatches = 3

    /// `candidateRefKeys`（端末写真の refKey 群）のうち未スキャン分を処理する。
    /// 進捗ごと・完了時に `onBatch` を呼ぶ（ピープル一覧の再読込に使う）。
    /// ⚠️ 既定値は**夜間ウィンドウ向け**（実機 diagnostics-72）。スキャンは前面では始めない
    /// （`startScan` が `scenePhase` で弾く）ので、ここで長く眠る相手はもう居ない。
    /// 旧値（8 枚ごとに 2.5 秒休止）は 5 分の窓のうち **87 秒を睡眠に使っていた**——
    /// 実作業は 1 枚 80ms で、280 枚＝22 秒しか進んでいなかった。
    /// 譲りは `shouldPause` が**1 枚ごと**に見るので、休止を短くしても応答性は落ちない。
    /// バッチを 16 に上げるのは、クラウド写真のサムネ往復（1 回 約 870ms）を半分に減らすため。
    func scan(candidateRefKeys: [String],
              batchSize: Int = 16,
              betweenBatchNs: UInt64 = 500_000_000,
              /// 1 単位ぶんの譲り待ちの上限（ADR-95）。**テストから縮めるための seam**——
              /// 既定の 60 秒のままだと「譲って畳む」経路のテストが 1 本 60 秒かかる。
              maxPauseNs: UInt64 = BackgroundTrickle.defaultMaxPauseNs,
              allowSimulator: Bool = false,
              shouldPause: @MainActor () -> Bool = { false },
              networkAllowed: @MainActor () -> Bool = { true },
              onProgress: @MainActor (Int) -> Void = { _ in },
              onBacklog: @MainActor (_ todo: Int, _ deferred: Int) -> Void = { _, _ in },
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
        // ⚠️ **終わりに 0 を報せない**（ADR-207）。以前は `onProgress(0)` を固定で返していたので、
        // 「全部終わった」と「譲って途中で畳んだ」が**同じ値**になり、残作業を抱えたまま
        // 「すべて解析済み」と表示していた。畳んだ時点の本当の残りを返す。
        var remainingNow = 0
        var deferredNow = 0
        defer {
            isRunning = false
            onProgress(remainingNow)
            onBacklog(remainingNow, deferredNow)
        }

        // ⚠️⚠️ **何度やっても画像が取れない写真は候補から外す**（ADR-243・実機ログ diagnostics-101）。
        // ADR-92 は「取れないのは一時的」を前提に記録せず次の窓へ回す決まりにしたが、実機には
        // **status=200 で 0 バイト**のサムネを返す写真があった——`loaded=0 nil=1` のまま
        // スキャン済みにならないので、6 時間ぶん毎回候補に戻り、その 1 枚のために
        // 86,772 件の列挙（約 11 秒）と人物一覧の作り直しが走り続けていた。
        //
        // ⚠️ **「残っている」の定義は台帳の 1 か所から取る**（ADR-254）。以前はここで
        // `!done.contains && !unreadable.contains` を 3 回書き写していて、`pendingCount` 側は
        // `unreadable` を引いていなかった——数える側と列挙する側で答えが食い違い、
        // 札が永久に立たなかった（実機ログ diagnostics-105・列挙 11 秒 × 24 回/セッション）。
        // 件数も同じ呼び出しで受け取る（8.6 万件の fetch を 2 往復払わない＝ADR-119）。
        let pending = await store.pendingRefKeys(candidateRefKeys: candidateRefKeys)
        // ローカル("L-")を必ず先に、クラウド("C-")は後回し（母数が巨大で細切れ窓では終わらないため）。
        // 回線が許可されない（例: Wi-Fi 待ち）ときはクラウド分を今回は対象から外す＝端末内写真だけ
        // 進める（Wi-Fi 復帰時の次回スキャンでクラウドを拾う。顔検出はキャッシュ済みサムネDLを要する）。
        let cloudOK = networkAllowed()
        let localTodo = pending.refKeys.filter { $0.hasPrefix("L-") }
        let cloudPending = pending.refKeys.filter { $0.hasPrefix("C-") }
        let cloudTodo = cloudOK ? cloudPending : []
        let todo = localTodo + cloudTodo
        // ⚠️ **回線待ちで外したぶんも数える**（ADR-207）。クラウド分を対象から外した回は
        // `todo` が実際の残作業より少なくなる。Wi-Fi が無い端末で端末内写真を配り終えると
        // `todo` が空になり、「もう無い」と読めてしまう——クラウドの顔は残っているのに。
        deferredNow = cloudOK ? 0 : cloudPending.count
        remainingNow = todo.count
        onBacklog(remainingNow, deferredNow)
        Diagnostics.mark("faces: start — candidates=\(candidateRefKeys.count) already=\(pending.scanned) "
                         + "todo=\(todo.count) (local=\(localTodo.count) cloud=\(cloudTodo.count)\(cloudOK ? "" : " deferred:no-wifi=\(deferredNow)"))"
                         + (pending.unreadable == 0 ? "" : " unreadable=\(pending.unreadable)"))
        guard !todo.isEmpty else {
            Diagnostics.mark("faces: nothing to scan (all done\(deferredNow > 0 ? ", \(deferredNow) waiting for Wi-Fi" : ""))")
            return
        }
        Self.log.info("face scan: start — \(todo.count) photos to scan (batch \(batchSize))")
        onProgress(todo.count)

        var index = 0
        var processed = 0
        var facesFound = 0
        var emptyStreak = 0   // 連続で 1 枚も解析できなかったバッチ数（ADR-179）
        // ⚠️⚠️ **実際に試して取れなかった写真だけ**を入れる（ADR-243・自己レビューで気づいた）。
        // `batch` から引き算してはいけない——`BackgroundTrickle` は譲りの打ち切り・取り消しで
        // **バッチの途中で抜ける**ので、`results` は `batch` より短くなる。差分を取ると
        // **一度も試していない写真を「取れなかった」と数える**ことになり、しかも todo の順番は
        // 安定しているので、毎回同じ写真が打ち切り位置に来て**本物の写真が外れる**。
        var attemptedButFailed: [String] = []
        // ⚠️ 停止判定は 1 枚単位（検出+埋め込みは 1 枚数百 ms〜。バッチ一括だと
        // ロック解除直後の譲りが遅れる）。保存はバッチ 1 回（T3）を維持。
        await BackgroundTrickle.run(
            betweenBatchNs: betweenBatchNs,
            shouldPause: shouldPause,
            pausePerfLabel: "face.pauseWait",   // センサー: 譲り待ちの発生数
            unitPerfLabel: "face.photoMs",
            maxPauseNs: maxPauseNs,
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
                guard let faces = one[refKey] else {
                    attemptedButFailed.append(refKey)   // 試した上で取れなかった（ADR-243）
                    return nil
                }
                return (refKey: refKey, faces: faces)
            },
            commitBatch: { batchIndex, batch, results in
                // 解析できた写真だけを記録する（nil＝画像が取れず未解析なので記録しない）。
                let records = results.compactMap { $0 }
                // ⚠️ **取れなかった写真を数える**（ADR-243）。取れた写真は記録を忘れる
                //    ——一時的な失敗（譲り・回線）を溜め込まないため。
                //    数えるのは 1 時間に 1 回まで（`FaceStore.scanFailureCooldown`）なので、
                //    1 つの窓で何千枚が巻き込まれても、それぞれ 1 回しか増えない。
                // ⚠️ 数えるのは**試した上で取れなかったもの**だけ（`batch` との差分ではない。
                //    上の `attemptedButFailed` の注記を参照）。
                let loaded = Set(records.map(\.refKey))
                let failed = attemptedButFailed
                attemptedButFailed.removeAll(keepingCapacity: true)
                if !failed.isEmpty {
                    let exhausted = await store.recordScanLoadFailures(failed)
                    if !exhausted.isEmpty {
                        Diagnostics.mark("faces: \(exhausted.count) 枚を候補から外す"
                                         + "（\(FaceStore.maxScanLoadFailures) 回・別の窓で画像が取れなかった）")
                    }
                }
                if !loaded.isEmpty { await store.clearScanLoadFailures(Array(loaded)) }
                guard !records.isEmpty else {
                    // 全件が未解析（画像が取れなかった＝譲った／回線／バッチ失敗）。
                    // ⚠️ **空のまま何バッチも進めない**（ADR-179）。以前は「進めて次へ」だったので、
                    // 画像が一切取れない状態が続くと**todo 全体を空で歩き切って** `finished —
                    // scanned=0` で終わり、次の窓でまた同じことを繰り返していた（実フィードバック
                    // 「夜間解析が進まなくなった」）。連続で空なら原因は続いているので、
                    // 窓を無駄にせず畳んで次の窓に回す。
                    emptyStreak += 1
                    if emptyStreak >= Self.maxEmptyBatches {
                        Diagnostics.mark("faces: \(emptyStreak) 連続で画像が取れないため今回は畳みます "
                                         + "（scanned=\(processed)/\(todo.count)・譲り／回線／取得失敗）")
                        return .stop
                    }
                    return batch.isEmpty ? .stop : .proceed
                }
                emptyStreak = 0
                facesFound += records.reduce(0) { $0 + $1.faces.count }
                await store.recordScans(records)   // T3: save はバッチ 1 回
                processed += batch.count
                AnalysisActivity.recordActivity(.faces)
                remainingNow = max(0, todo.count - processed)
                onProgress(remainingNow)

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
