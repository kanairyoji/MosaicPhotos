import AutoAlbumCore
import BackgroundTasks
import BackupKit
import MosaicSupport
import SwiftUI
import PhotosFeatureKit

// MARK: - Heavy work in background (BGProcessingTask)

/// スクリーンロック中（アプリがバックグラウンド）に重い処理を進めるスケジューラ。
///
/// 方針（ユーザー指定）: アルバム生成・CLIP 埋め込み・顔スキャンは「電源接続＋アイドル」でのみ動く。
/// フォアグラウンドでは `BackgroundYield.heavyWorkAllowed`（60 秒アイドル）が同じ判定を行い、
/// ロック中はこの `BGProcessingTask` が OS に起こされて続きを進める（`requiresExternalPower = true`
/// なので **電源に接続されていない限り OS は起動しない**）。
///
/// 実行内容はフォアグラウンドの背景処理と同一（generate 差分・CLIP 埋め込み・顔スキャン）で、
/// 各ループは `Task.isCancelled` を見るため、OS の期限切れ（expiration）で速やかに停止する。
enum HeavyWorkScheduler {
    /// ⚠️ `nonisolated`：アプリターゲットは `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` なので、
    /// 無印だと MainActor 隔離になる。この値は `BGTaskScheduler.getPendingTaskRequests` の
    /// **完了ハンドラ（任意スレッド）**から読むため、MainActor 隔離のままだと Swift 6 でエラーになる
    /// （Swift 5 モードでは警告すら出ないが、実際に別スレッドから MainActor 状態を触っている）。
    /// 不変の `let` なので nonisolated で安全。
    nonisolated static let taskID = "com.kanai.MosaicPhotos.heavywork"

    /// 解析（顔・埋め込み）の残作業を理由にアルバム生成を見送れる連続回数。
    /// これを超えたら生成に窓を明け渡す（生成も飢えさせない）。
    private static let maxGenerateDeferrals = 4

    /// フォアグラウンドで構築済みのストア群（RootView が設定）。アプリがメモリに残ったまま
    /// BG 起動された場合はこれを再利用し、プロセス再起動時のみ作り直す。
    static var stores: HomeStores?

    /// アプリ起動時（App.init）に必ず呼ぶ（launch 完了前の登録が必須）。
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in handle(task) }
        }
    }

    /// 起動時の保険（B）: 予約が残っていなければ入れ直す。
    /// force-quit 後の復帰や OS 側の予約破棄で「いつまでも予約が無い」状態を防ぐ。
    static func submitIfMissing() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            // ⚠️ この完了ハンドラは**任意スレッド**で呼ばれる。`submit()` は MainActor 隔離
            //（アプリ既定）なので、直接呼ばず MainActor へ跳ぶ。
            guard !requests.contains(where: { $0.identifier == taskID }) else { return }
            Task { @MainActor in submit() }
        }
    }

    /// バックグラウンド遷移時に次回実行を予約する。電源接続が条件（OS が満たされるまで起動しない）。
    static func submit() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        // 電源条件はユーザーの電源ポリシー（Background & Battery）に従う（ADR-80）。
        // 「常に」を選んでいれば電源なしでも OS に起こしてもらう。既定（充電中のみ）は従来どおり。
        request.requiresExternalPower = PowerStateMonitor.shared.policy == .whileCharging
        request.requiresNetworkConnectivity = false // ローカル写真の処理は回線不要（クラウド分は回線ポリシーが弾く）
        do {
            try BGTaskScheduler.shared.submit(request)
            Diagnostics.mark("bgtask: submitted")
        } catch {
            // シミュレータ等では未サポートで失敗する（実害なし）。
            DiagnosticsLog.shared.append("bgtask: submit failed — \(error.localizedDescription)")
        }
    }

    /// 実行中の重い処理タスク（BGTask 本体）。フォアグラウンド復帰で止めるために保持する（ADR-79）。
    /// 世代つきで持つ（⚠️ A をキャンセル後に B が始まり、その後 A が終了したときに、
    /// A が **B のハンドルを消す**のを防ぐ＝`GenerationHandle`・レビュー指摘）。
    private static let currentWork = GenerationHandle<Task<Void, Never>>()

    /// BGTask の完了通知ラッチ。**`setTaskCompleted` は 1 回だけ**呼べる（二重に呼ぶと
    /// BGTaskScheduler が例外を投げる）。期限切れハンドラと本体の終了処理がどちらも呼び得るので、
    /// ここで 1 回に絞る。世代トークンで**前の実行から遅れて来た通知**も弾く
    /// （`CompletionLatch` はテスト済み）。
    private static let completionLatch = CompletionLatch()

    private static func handle(_ task: BGProcessingTask) {
        Diagnostics.mark("bgtask: begin")
        let started = Date()
        // この実行の世代。以後の完了通知はこのトークンを添えて行う
        // （前の実行の遅れた通知がこの枠を奪わないように）。
        let token = completionLatch.begin()

        /// 完了通知＋再予約を**一度だけ**行う。
        @MainActor func completeOnce(outcome: String, success: Bool) {
            completionLatch.completeOnce(token) {
                Diagnostics.mark("bgtask: end (\(outcome))")
                recordLastRun(started: started, outcome: outcome)
                task.setTaskCompleted(success: success)
                submit()   // 次回分を再予約（残作業はまた次のロック中に進む）
            }
        }

        let work = Task { @MainActor in
            await runHeavyWork()
            let cancelled = Task.isCancelled
            currentWork.clearIfCurrent(token: token)   // 自分が現行のときだけ手放す
            completeOnce(outcome: cancelled ? "cancelled" : "completed", success: !cancelled)
        }
        currentWork.set(work, token: token)
        task.expirationHandler = {
            // OS の持ち時間切れ。各ループは Task.isCancelled で速やかに止まる。
            Diagnostics.mark("bgtask: expired — cancelling")
            work.cancel()
            Task { @MainActor in
                // ⚠️ 期限切れ側は**止めるところまで**面倒を見る。BGTask 本体（`work`）を
                // cancel しても、そこから起こした顔スキャン・背景処理は別 Task なので
                // 止まらない。OS へ完了を通知した後も走り続ける（レビュー指摘）。
                stopBackgroundProcessing(cancelBackup: true)
                completeOnce(outcome: "expired", success: false)
            }
        }
    }

    /// BGTask から起こした**別 Task の処理**を止める。
    ///
    /// `runHeavyWork` は顔スキャン（`startScan`）と背景埋め込み/タグ（`restartBackgroundFill`）を
    /// **起動するだけ**で、その完了を待っていない（窓を食い潰さないための設計）。
    /// そのため `work.cancel()` だけでは止まらない。期限切れ・フォアグラウンド復帰では
    /// これらも明示的に止める（各処理は差分ベースなので次の窓で続きから再開する）。
    /// - Parameter cancelBackup: 夜間バックアップも止めるか。
    ///   期限切れは true（プロセスが吊るされる前に明示キャンセルする方が安全）。
    ///   フォアグラウンド復帰は false——**ユーザーが自分で始めたバックアップ**と区別できないため、
    ///   復帰しただけで止めてはいけない（従来の挙動を維持する）。
    @MainActor
    private static func stopBackgroundProcessing(cancelBackup: Bool) {
        guard let stores else { return }
        // 解析セッション（ADR-182）の作業は処理枠の都合では止めない（OS の継続タスクが面倒を見る）。
        if !stores.analysisSession.isActive {
            stores.peopleEngine.stopScan()
            stores.autoAlbumEngine.stopBackgroundWork()
        }
        if cancelBackup, stores.backupEngine.isRunning { stores.backupEngine.cancel() }
    }

    // MARK: - フォアグラウンド復帰（ADR-79）

    /// アプリがアクティブになったときに呼ぶ。夜間処理（BGTask ルーチン・顔スキャン・タグ付け/
    /// 埋め込み）を**明示的に止める**。
    ///
    /// 従来はゲート（`BackgroundYield`）が閉じるだけで、各トリクルは `waitWhilePaused` で
    /// 眠って待機していた。この方式では実行中の 1 単位が最後まで走り、モデルを抱えたまま眠る。
    /// 明示キャンセルなら実行中の単位が終わり次第すぐ降り、モデルも解放される。
    /// 各処理は差分ベースなので、次の夜間窓で続きから再開する（取りこぼしなし）。
    static func stopForForeground() {
        // ⚠️ 最重要（ADR-79 追記）: **復帰そのものを「操作」として記録**する。
        // これが無いと `idleSeconds` は離席前の最終タッチからの経過のままなので、戻った瞬間に
        // 「20 秒以上アイドル」と判定され、前面の定期ループ（HomeView → refreshIfNeeded）が
        // その場で generate を起動していた（実機ログ diagnostics-31: 復帰と同時に generate が
        // 22.8 秒走り、メインが 2.4s/1.7s/5.9s/3.9s ブロック＝体感のカクつきの正体）。
        BackgroundActivityMonitor.shared.noteUserInteraction()

        let hadWork = currentWork.current != nil
        currentWork.current?.cancel()
        currentWork.clear()
        // BGTask のルーチンが起こした fire-and-forget のタスク群は、上の cancel では止まらない
        // （構造化されていないため）。エンジンへ個別に停止を伝える。
        // ⚠️ 解析セッション（ADR-182）の作業は**利用者が始めたもの**なので復帰では止めない。
        if stores?.analysisSession.isActive != true {
            stopBackgroundProcessing(cancelBackup: false)
        }
        if hadWork { Diagnostics.mark("bgtask: stopped for foreground") }
    }

    /// D: 前面/背面の遷移を実測ログに残す（復帰時のカクつき調査用）。
    /// 「復帰の瞬間に何が走っていたか」をログ 1 行で特定できるようにする。
    static func noteScenePhase(_ label: String) {
        let monitor = BackgroundActivityMonitor.shared
        let running = [
            monitor.isEmbedding ? "embedding" : nil,
            monitor.isScanningFaces ? "faces" : nil,
            stores?.autoAlbumEngine.isGenerating == true ? "generating" : nil,
            stores?.backupEngine.isRunning == true ? "backup" : nil,
            currentWork.current != nil ? "bgtask" : nil,
        ].compactMap { $0 }
        Diagnostics.mark("scene: \(label) — running=[\(running.joined(separator: ","))] "
                         + "embedRemaining=\(monitor.embedRemaining) faceRemaining=\(monitor.faceScanRemaining)")
    }

    // MARK: - 検証用（Developer Options・デバッガ不要）

    /// BG タスクが OS に予約されているか（"scheduled" / "none"）。
    static func pendingStatus() async -> String {
        await withCheckedContinuation { cont in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                cont.resume(returning: requests.contains { $0.identifier == taskID } ? "scheduled" : "none")
            }
        }
    }

    /// 検証実行中か（Developer Options のスピナー用）。
    static var isDebugRunning = false

    /// BG タスクと**同じルーチン**をその場で実行する（デバッガ不要の検証用）。
    /// 実際の「ロック中に OS が起こす」部分は OS 裁量のため検証できないが、
    /// ルーチン本体（ストア構築/再利用・Keychain 読み・generate/顔/埋め込み・完了判定）を
    /// 前景で確認できる。実行中はゲートを一時的に全開にし、終了時に元へ戻す。
    static func debugRunNow(timeLimit: TimeInterval = 180) {
        guard !isDebugRunning else { return }
        isDebugRunning = true
        Diagnostics.mark("bgtask: debug run begin (limit=\(Int(timeLimit))s)")
        let started = Date()
        let previousForce = BackgroundYield.debugForceHeavyWork
        BackgroundYield.debugForceHeavyWork = true

        let work = Task { @MainActor in
            // 前面から叩くデバッグ実行。終わったら「非アクティブ扱い」を元へ戻す。
            await runHeavyWork(restoreAppActive: true)
            finish(outcome: "manual-completed")
        }
        // 時間制限（実 BG の期限切れを模擬）。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeLimit))
            if isDebugRunning {
                work.cancel()
                // 実 BG の期限切れと同じく、起こした処理も止める（cancel だけでは止まらない）。
                stopBackgroundProcessing(cancelBackup: true)
                finish(outcome: "manual-expired")
            }
        }

        func finish(outcome: String) {
            guard isDebugRunning else { return }
            isDebugRunning = false
            BackgroundYield.debugForceHeavyWork = previousForce
            Diagnostics.mark("bgtask: debug run end (\(outcome))")
            recordLastRun(started: started, outcome: outcome)
        }
    }

    /// 「残作業があるのに長期間動いていない」解析パスを診断ログへ出す（ADR-87）。
    /// 飢餓バグ（ADR-72/85/86）は**沈黙として現れる**ため、こちらから沈黙を検出しにいく。
    /// 判定は `AnalysisStallCheck`（純ロジック・テスト済み）。健全なら何も出さない。
    private static func logStalledPasses(stores: HomeStores) async {
        let progress = await stores.autoAlbumEngine.analysisProgress()
        let states: [AnalysisStallCheck.PassState] = [
            .init(pass: .sceneTags, pending: max(0, progress.total - progress.sceneTagged),
                  lastActivity: AnalysisActivity.lastActivity(.sceneTags)),
            .init(pass: .embeddings, pending: max(0, progress.total - progress.embedded),
                  lastActivity: AnalysisActivity.lastActivity(.embeddings)),
            .init(pass: .faces, pending: stores.peopleEngine.remaining,
                  lastActivity: AnalysisActivity.lastActivity(.faces)),
        ]
        // 一度も動いていないパスは「この端末で解析が始まり得た時刻」からの経過で判定する。
        // 初回起動時刻が無ければ今を記録しておく（新規インストール直後の誤検知を防ぐ）。
        let key = AppSettingsKeys.firstLaunchAt
        let installedAt: Date
        if let stored = UserDefaults.standard.object(forKey: key) as? Double {
            installedAt = Date(timeIntervalSinceReferenceDate: stored)
        } else {
            installedAt = Date()
            UserDefaults.standard.set(installedAt.timeIntervalSinceReferenceDate, forKey: key)
        }
        if let line = AnalysisStallCheck.logLine(states, now: Date(), installedAt: installedAt) {
            Diagnostics.mark(line)
        }
    }

    /// D: 最終実行の記録（Developer Options で表示）。ログを開かずに夜間実行の有無を確認できる。
    private static func recordLastRun(started: Date, outcome: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let mins = Int(Date().timeIntervalSince(started) / 60)
        UserDefaults.standard.set("\(f.string(from: started)) — \(outcome) (\(mins)m)",
                                  forKey: AppSettingsKeys.bgTaskLastRun)
    }

    /// 重い処理を一通り進める。フォアグラウンドと同じゲート（heavyShouldPause）を通るが、
    /// BG 中は操作が発生しないためアイドル条件は自然に満たされる。
    /// - Parameter restoreAppActive: 終了時に `BackgroundYield.isAppActive` を元へ戻すか。
    ///   フォアグラウンドから叩くデバッグ実行（`debugRunNow`）は true——戻さないと、
    ///   次の scenePhase 変化まで「非アクティブ扱い」が残り、**ユーザー操作中でも重い処理が
    ///   走り続ける**（レビュー指摘）。実際の BGTask は false（非アクティブが正しい状態）。
    private static func runHeavyWork(restoreAppActive: Bool = false) async {
        // BGTask 実行中＝アプリは非アクティブ確定。バックグラウンド起動では scenePhase の
        // 変化が来ないことがあり、初期値（true）のままだと中央ゲートが開かない。
        let previousActive = BackgroundYield.isAppActive
        let previousBackground = BackgroundYield.isAppInBackground
        BackgroundYield.isAppActive = false
        // 背面起動では scenePhase の変化が来ないことがある。処理枠の間は「背面」を明示し、
        // 前面の定期ループ（HomeView）に判断させない（diagnostics-74・`isAppInBackground` の注記）。
        BackgroundYield.isAppInBackground = true
        defer {
            if restoreAppActive {
                BackgroundYield.isAppActive = previousActive
                BackgroundYield.isAppInBackground = previousBackground
            }
        }
        // ストア群：プロセス内で唯一の共有インスタンス（前景 RootView と同じ）。別々に build すると
        // PeopleEngine/AutoAlbumEngine が二重化し顔/タグが二重起動するため必ず shared() を使う。
        let stores = await HomeStores.shared()
        Self.stores = stores
        if Task.isCancelled { return }

        // 1. 顔スキャン＋CLIP 埋め込み/タグを**先に**開始する（それぞれ内部でトリクル実行・
        //    1枚ごとに譲り判定）。BG 窓は短く（数秒〜数分で expire することが多い）、generate を
        //    先に await すると窓を食い潰して顔/埋め込みが開始すらしない実障害があった（Fix C）。
        //    これらは端末内写真なら通信不要で走る（Fix B・ローカルゲート）。
        // シミュレータでは FaceTagger が既定でスキップするため、**この BG ルーチンでは顔スキャンを許可**
        // する（`debugForceHeavyWork`＝「Run BG routine now」/ゲート強制時、または「Face scan in
        // Simulator」トグル ON 時）。これが無いと Run BG routine を押しても People が増えなかった。
        let allowSim = BackgroundYield.debugForceHeavyWork
            || UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)

        // 顔スキャンを起こす（差分ベース・毎窓）。旧キャプション窓の順番回し（ADR-86/93）は
        // VLM 廃止（ADR-108）で不要になった＝窓はタグ・埋め込み・顔スキャンで使い切る。
        // ⚠️ 解析セッション（ADR-182）が走っているなら同じトリクルが既に全力で動いている。
        // 重ねて起こさない（restart は実行中の埋め込みを一度畳んでしまう）。
        if stores.analysisSession.isActive {
            Diagnostics.mark("bgtask: analysis session active — not starting analysis here")
        } else {
            let candidates = await analysisOrderedRefKeys(dropboxStore: stores.dropboxStore)
            // 無くなった写真の顔を掃除してから（削除・配置替え・同期対象外＝ADR-175 後に残る幽霊）。
            await stores.peopleEngine.pruneMissingPhotos(candidateRefKeys: candidates)
            if Task.isCancelled { return }
            stores.peopleEngine.startScan(candidateRefKeys: candidates, allowSimulator: allowSim)
            // 夜間窓は重い処理のための特権時間。前面で始まって眠っている実行が居座っていると窓を
            // 丸ごと空転させるので、明け渡させてから始め直す（ADR-95）。
            stores.autoAlbumEngine.restartBackgroundFill()
        }

        // 「動くべきなのに動いていない」パスを毎窓チェックして診断ログへ（ADR-87）。
        // 飢餓バグは沈黙として現れるため、こちらから沈黙を検出しにいく。
        await logStalledPasses(stores: stores)

        // 1.5 バックアップ（ADR-42）: 宛先が Dropbox のとき、夜間ウィンドウで自動実行する。
        // 経緯: ADR-72「埋め込み残 0 の窓だけ」→ 事実上始まらない（diagnostics-20）→ 4 回に 1 回の
        // 順番回し → ADR-180 で**毎窓・解析と並行**へ（資源が重ならないため）。
        // ADR-180: バックアップは解析と**並行して**毎窓起こす（見送りは廃止）。
        // 以前は「埋め込みの残作業が無い窓だけ」→「4 回に 1 回」と譲っていたが、バックアップは
        // ディスク読み＋通信で、CPU/ANE をほぼ使わない。解析（推論）とは資源が重ならないので、
        // 同じ窓で走らせても互いを遅くしない。譲らせていた根拠（メモリのピーク・ADR-72）は
        // 1 枚ずつ読んで上げる trickle 実装では当たらない（実測 footprint は解析側が支配的）。
        // 実フィードバック「バックアップは画像処理と並行して動かしてよい。現状あまり動いていない」。
        let embedBacklog = await stores.autoAlbumEngine.pendingEmbedCount()
        if embedBacklog > 0 {
            Diagnostics.mark("bgtask: backup alongside analysis (embed backlog=\(embedBacklog))")
        }
        stores.backupEngine.startNightlyIfEnabled()

        // 2. アルバム生成（差分があるときだけ・~26s 上限）。**顔/埋め込みを起こした後**に回す。
        // generate はピークが大きく（実測 ~550〜880MB）BG の厳しい jetsam 上限に触れてアプリごと
        // kill され、進捗が振り出しに戻る主因だった。残り許容量に**十分**な余裕がある時だけ実行する
        // （閾値を 700→900MB に引き上げ・Fix A）。余裕が無ければスキップし軽い処理だけ進める。
        // ⚠️ **同じ窓で生成と解析を同時に走らせない**（実機 diagnostics-72）。
        // 生成は `isGeneratingAlbums` を立て、`heavyShouldPause()` はそれを見て譲るので、
        // 生成が始まった瞬間に顔スキャンと埋め込みが止まる。しかも生成自体は 26 秒では
        // 終わらず**毎回 `generate: aborted`**（このログでは中断 3 回・完了 0 回）。
        // 結果、窓は「止まった解析＋終わらない生成」で丸ごと空転していた
        // （5 分の窓で顔は 280 枚＝実作業 22 秒ぶんしか進んでいない）。
        // 残作業があるうちは生成を見送り、**窓ごとに 1 つの仕事を終わらせる**。
        // ただしバックアップと同じく上限つきで順番を回す（生成も飢えさせない）。
        let faceBacklog = stores.peopleEngine.remaining
        let genDeferrals = UserDefaults.standard.integer(forKey: AppSettingsKeys.generateDeferralStreak)
        // 判定は純ロジック（`NightlyWorkPolicy`・テスト済み）。ここは反映だけ。
        switch NightlyWorkPolicy.generateDecision(embedBacklog: embedBacklog, faceBacklog: faceBacklog,
                                                  deferrals: genDeferrals,
                                                  maxDeferrals: Self.maxGenerateDeferrals) {
        case .defer_(let streak):
            UserDefaults.standard.set(streak, forKey: AppSettingsKeys.generateDeferralStreak)
            Diagnostics.mark("bgtask: defer generate \(streak)/\(Self.maxGenerateDeferrals) "
                             + "(embed=\(embedBacklog) faces=\(faceBacklog))")
        case .run(let afterDeferrals):
            UserDefaults.standard.set(0, forKey: AppSettingsKeys.generateDeferralStreak)
            if afterDeferrals > 0 {
                Diagnostics.mark("bgtask: generate turn (deferred \(afterDeferrals)x, "
                                 + "embed=\(embedBacklog) faces=\(faceBacklog))")
            }
            let availableMB = MemoryBudget.availableBytes() / 1_048_576
            if availableMB > 900 {
                await stores.autoAlbumEngine.refreshIfNeeded()
            } else {
                Diagnostics.mark("bgtask: skip generate (available=\(availableMB)MB)")
            }
        }
        if Task.isCancelled { return }

        // 2.5 家族共有（ADR-166）: 反映と受信は**夜間にも回す**。
        // ⚠️ これまでの起動条件は「起動 25 秒後」「バックアップ完走後」「手動」だけで、
        // アプリを開かない日が続くと**反映も自己修復も走らなかった**（外部削除された写真が
        // 戻らないまま放置される）。回線ポリシーは各処理の内側が見る。
        if NetworkStateMonitor.shared.networkAllowed() {
            await stores.shareImporter.runIfNeeded()
            if ShareSettingsKeys.isProvideEnabled() { await stores.shareEngine.syncNow() }
        }
        if Task.isCancelled { return }

        // 2.6 バックアップ台帳と Dropbox の実体を**週 1 回**照合する（ADR-166）。
        // 実体が消えていても台帳は「済み」のままなので、放っておくと気づけない
        // （共有の自己修復もコピー元が無くて失敗し続ける）。全件一覧なので毎晩はやらない。
        await stores.backupEngine.reconcileIfDueWeekly()
        if Task.isCancelled { return }

        // 3. 残作業が続く限り待つ（期限切れ＝キャンセルで抜ける）。進捗はモニタで観測。
        let monitor = BackgroundActivityMonitor.shared
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            let working = monitor.isEmbedding || monitor.isScanningFaces
                || monitor.embedRemaining > 0 || monitor.faceScanRemaining > 0
                || stores.backupEngine.isRunning
            if !working { break }   // 全部片付いた
        }
        // 期限切れ（キャンセル）時は夜間バックアップも止める（アップロード途中で
        // プロセスが吊るされるより明示キャンセルが安全。「済み」記録は検証後のみ
        // 付くので、中断しても次回に差分から再開される）。
        if Task.isCancelled, stores.backupEngine.isRunning {
            stores.backupEngine.cancel()
        }
    }
}
