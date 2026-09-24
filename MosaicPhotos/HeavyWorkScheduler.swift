import AutoAlbumCore
import BackgroundTasks
import BackupKit
import MobileCLIPKit
import MosaicSupport
import SwiftUI
import PhotosFeatureKit

// MARK: - Heavy work in background (BGProcessingTask)

/// スクリーンロック中（アプリがバックグラウンド）に重い処理を進めるスケジューラ。
///
/// 方針（ユーザー指定）: アルバム生成・CLIP 埋め込み・顔スキャンは「電源接続＋アイドル」でのみ動く。
/// フォアグラウンドでは `BackgroundYield.allows(.cloudTrickle)`（60 秒アイドル）が同じ判定を行い、
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
            // ⚠️ 予約は「候補に載せた」だけ。**本当に積まれているか**と、そのときの端末条件を
            //    台帳に残す（diagnostics-81: 12 時間 窓が来なかったとき、これが無かったので
            //    「予約が消えていた」のか「OS が実行しなかった」のか区別できなかった）。
            RunTimeline.record("submit: requiresPower=\(request.requiresExternalPower) "
                               + environmentLine())
            logPendingRequests(context: "submit")
        } catch {
            // シミュレータ等では未サポートで失敗する（実害なし）。
            DiagnosticsLog.shared.append("bgtask: submit failed — \(error.localizedDescription)")
            RunTimeline.record("submit failed — \(error.localizedDescription)")
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
        // ⚠️ **窓と窓の間隔を残す**（diagnostics-81）。「窓が来ない」は沈黙として現れるので、
        //    来たときに前回からの経過を書いておかないと、後から「何時間空いたか」を数えられない。
        let sinceLast = Self.minutesSinceLastWindow()
        Self.recordWindowBegin()
        let gapText = sinceLast.map { " (前回の窓から \($0) 分)" } ?? " (この端末で最初の窓)"
        Diagnostics.mark("bgtask: begin" + gapText)
        RunTimeline.record("window begin\(gapText) " + Self.environmentLine())
        RunTimeline.noteState("window", active: true)
        let started = Date()
        // この実行の世代。以後の完了通知はこのトークンを添えて行う
        // （前の実行の遅れた通知がこの枠を奪わないように）。
        let token = completionLatch.begin()

        /// 完了通知＋再予約を**一度だけ**行う。
        @MainActor func completeOnce(outcome: String, success: Bool) {
            completionLatch.completeOnce(token) {
                Diagnostics.mark("bgtask: end (\(outcome))")
                // ⚠️ **モデルを抱えたまま眠らない**（ADR-223・実機ログ diagnostics-88）。
                // 窓の中で CLIP テキスト塔（505MB）と顔モデル（650MB）を読み、そのまま
                // 30 分の眠りに入っていた——背面のアプリは footprint の大きい順に落とされる。
                // 前面なら手放さない（次の操作が再ロード待ちになる）。
                //
                // ⚠️ **ブースト中は手放さない**（レビュー指摘）。「今すぐ解析」はアプリを閉じても
                // 続く（ADR-182）ので、窓が期限切れで終わっても**走り続けている**。
                // ここで取り上げると、その場で 10〜35 秒の再ロードが始まり、
                // `MLInferenceGate` の中なので**その間すべての推論が止まる**。
                // 窓の作業を止める側（`stopBackgroundProcessing`）も同じ免除を持っている。
                if stores?.analysisSession.isActive == true {
                    Diagnostics.mark("models kept (boost still running)")
                } else {
                    PerceptionModels.releaseForIdle(reason: "window \(outcome)")
                }
                let mins = Int(Date().timeIntervalSince(started) / 60)
                RunTimeline.record("window end (\(outcome)・\(mins) 分) " + Self.environmentLine())
                RunTimeline.noteState("window", active: false)
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

    /// 背面に落ちたので、**誰も使っていないモデルを手放す**（ADR-226 追補）。
    ///
    /// ⚠️ ADR-223 の解放点は「窓の終わり」と「顔スキャン 1 巡」の 2 つだけだった。そのため
    /// **前面で検索やタグ表示のために読んだ CLIP テキスト塔（実測 footprint 505MB）は、
    /// 背面へ落としても次の窓が終わるまで残る**（電源が無ければ永久に）。画像キャッシュを
    /// 背面で絞るのと同じ理屈がモデルにも当てはまる。
    /// ⚠️ ただし**窓やブーストが走っている間は手放さない**——走っている解析から取り上げると、
    /// その場で 10〜35 秒の再ロードが始まり、ゲートの中なのでほかの推論も止まる。
    @MainActor
    static func releaseModelsIfIdleInBackground() {
        // ⚠️ **配列とモデルで条件が違う**（レビュー指摘）。ADR-228 で判定を 1 つに寄せたとき、
        // この下の 2 行（作り直せる大きな配列＝候補 12MB・顔の候補 10MB・AI の下ごしらえ 30MB）
        // まで新しい厳しい条件で塞いでしまっていた。配列は**走っている解析が困らない**
        // （次に要るときに作り直す）ので、元どおりの条件で落とす。ここを塞ぐと、
        // 前面のトリクル中にホームへ抜けただけで 52MB が背面のあいだ居座り、
        // 解放点が他に無いので次の窓まで残る——ADR-226 が消したはずの jetsam 露出そのもの。
        // ⚠️ 条件は `isHeavyWorkRunning`（窓＋ブースト）を**使い回す**。同じ式をここに
        // 書き写すと、片方だけ直したときに静かに食い違う（ADR-196 の「11 述語」の入口）。
        if !isHeavyWorkRunning {
            stores?.analysisDriver.releaseCachesForBackground()
            stores?.autoAlbumEngine.releaseSuggestionSnapshot()
        }
        // モデルは**走っている解析から取り上げない**（取り上げると 10〜35 秒の再ロードが
        // その場で始まり、ANE ゲートの中なのでほかの推論も止まる）。
        guard !isAnalysisRunning else { return }
        PerceptionModels.releaseForIdle(reason: "background")
    }

    /// **前面でも、一定時間まったく使われていないモデルは手放す**（常駐メモリの棚卸し）。
    /// `AnalysisDriver` のアイドル監視（5 秒刻み）から呼ばれる。
    ///
    /// ⚠️ ADR-223 の「前面では手放さない」は、**窓の終わりに手放すか**という問いへの答えで、
    /// 「前面で放置され続けた場合」を見ていなかった。検索を 1 回すればテキスト塔
    /// （実測 footprint 505MB）が載り、以後は critical 圧迫か背面化まで載りっぱなしになる。
    /// 線引き（既定 5 分・`ModelIdlePolicy`）は「誰も待っていない時間に再ロード代を払う」
    /// という前提が崩れない長さにしてある。
    ///
    /// ⚠️ 条件の**出どころ**は背面側と同じ（`isCLIPBusy` / `isFaceModelBusy` と、その合成の
    /// `isAnalysisRunning`）。解放点ごとに別々の述語を書き起こすと、どれが効いたのか
    /// 実機ログから切り分けられなくなる（ADR-196 の「11 述語」と同じ轍）。
    /// 前面はモデルごとに、背面は合成を使う——**式は 1 組、使い分けるのは粒度だけ**。
    @MainActor
    static func releaseModelsIfIdleInForeground() {
        // ⚠️ **モデルごとに渡す**（レビュー 10 周目）。1 つにまとめると、顔スキャンが
        // 走っているだけで CLIP テキスト塔（505MB）まで手放せなくなる——顔スキャンは
        // CLIP を使わないのに。前面のブーストは 10 分以上続くことがあるので実際に効く。
        PerceptionModels.releaseIfIdle(clipBusy: isCLIPBusy, faceBusy: isFaceModelBusy)
    }

    /// CLIP を使う処理が走っているか。
    ///
    /// ⚠️ `isGeneratingAlbums` を含めているのは**安全側に倒しているだけ**で、
    /// 「生成が CLIP を引く」と確かめたわけではない（`AutoAlbumEngine.generate()` は
    /// メタデータのエンリッチが主で、Vision タグと埋め込みは別のトリクルが付ける）。
    /// 生成は 20〜45 秒で終わるので、その間だけ抱えても代償は小さい——
    /// 逆に外して取りこぼすと 10〜35 秒の再ロードになる。**確かめずに外さない**。
    ///
    /// ⚠️ AI アルバムの再評価は CLIP を引くが、ここには現れない。あちらは
    /// `encodeText` のたびに記録が更新されるので、時刻の側で守られる。
    @MainActor
    private static var isCLIPBusy: Bool {
        isHeavyWorkRunning
            || BackgroundActivityMonitor.shared.isEmbedding
            || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }

    /// 顔モデルを使う処理が走っているか。
    @MainActor
    private static var isFaceModelBusy: Bool {
        isHeavyWorkRunning || BackgroundActivityMonitor.shared.isScanningFaces
    }

    /// どちらのモデルも使い得る「まとまった仕事」が走っているか（窓・ブースト）。
    @MainActor
    private static var isHeavyWorkRunning: Bool {
        currentWork.current != nil || stores?.analysisSession.isActive == true
    }

    /// 解析（窓・ブースト・埋め込み・顔スキャン・アルバム生成）が走っているか。
    /// モデルを取り上げてよいかの唯一の判定。
    ///
    /// ⚠️ **背面側の挙動もこれで変わった**（ADR-228 で 1 つに寄せたときの副作用）。
    /// 以前の背面の条件は「窓の仕事」と「ブースト」の 2 つだけで、前面のトリクルが
    /// 埋め込み中に背面へ落ちると、**走っているその処理からモデルを取り上げて**いた
    /// （次の 1 枚で 10〜35 秒の再ロードが始まる）。埋め込み・顔スキャン・生成を足したのは
    /// その穴を塞ぐためで、意図した変更。
    ///
    /// ⚠️ 代償: `isEmbedding` / `isScanningFaces` には `isGeneratingAlbums` のような
    /// 時間切れの安全弁が無い（状態機械の `onStateChange` 由来なので立ちっぱなしに
    /// なりにくいが、絶対ではない）。立ちっぱなしになったときの影響は
    /// **「モデルが解放されない」だけで、解析そのものは止まらない**——
    /// `isGeneratingAlbums` に安全弁が要ったのは、あちらが**仕事を塞ぐ**判定だったから。
    /// ここは塞がないので、valve は足さない。
    @MainActor
    private static var isAnalysisRunning: Bool { isCLIPBusy || isFaceModelBusy }

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

        let work = Task { @MainActor in
            // 前面から叩くデバッグ実行。ゲートの免除も画面状態もスコープで入るので、
            // 本番の窓との違いは**時間制限だけ**になる（旧 `restoreAppActive` は不要）。
            await BackgroundYield.withExemption(.debug) { await runHeavyWork() }
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
            // ⚠️ **`remaining` は使わない**（ADR-207・レビュー 7 周目）。あれはスキャン中しか
            // 書かれないので、`kick` の直後に走るこの検査からは**常に 0**に見える。
            // `stalled` は `pending > 0` を入口にしているので、顔の停滞は
            // **一度も検出できなかった**——沈黙を検出しにいく仕組みが、それ自体沈黙していた
            // （ADR-87 が守りたかったのはまさにこの形の飢餓バグ）。
            .init(pass: .faces,
                  pending: stores.peopleEngine.faceBacklog ?? stores.peopleEngine.scanProgressRemaining,
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

    /// いまの端末条件を 1 行で（台帳用）。**窓が来ない理由の候補を、来たときに全部残す**。
    static func environmentLine() -> String {
        let refresh: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: refresh = "on"
        case .denied: refresh = "OFF(ユーザー設定)"
        case .restricted: refresh = "制限"
        @unknown default: refresh = "?"
        }
        let power = PowerStateMonitor.shared
        let battery = power.batteryLevel >= 0 ? "\(Int(power.batteryLevel * 100))%" : "?"
        let thermal = ProcessInfo.processInfo.thermalState
        let available = MemoryBudget.availableBytes() / 1024 / 1024
        let footprint = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        return "[bgRefresh=\(refresh) 充電=\(power.isOnPower) 電池=\(battery) "
            + "低電力=\(power.isLowPowerMode) 熱=\(thermal.rawValue) "
            + "footprint=\(footprint) 空き=\(available)MB]"
    }

    /// OS に積まれている予約を台帳へ書く（消えていれば「予約が無い」と分かる）。
    static func logPendingRequests(context: String) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let list = requests.isEmpty
                ? "なし"
                : requests.map { r in
                    let when = (r as? BGProcessingTaskRequest)?.earliestBeginDate
                    return r.identifier + (when.map { " (>= \($0))" } ?? "")
                }.joined(separator: ", ")
            RunTimeline.record("pending(\(context)): \(list)")
        }
    }

    /// 直近に窓が開いた時刻（間隔の計測用）。
    private static func recordWindowBegin() {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: AppSettingsKeys.bgTaskLastBeginAt)
    }

    /// 前回の窓からの経過（分）。まだ一度も開いていなければ nil。
    static func minutesSinceLastWindow(now: Date = Date()) -> Int? {
        let raw = UserDefaults.standard.double(forKey: AppSettingsKeys.bgTaskLastBeginAt)
        guard raw > 0 else { return nil }
        return Int(now.timeIntervalSince(Date(timeIntervalSinceReferenceDate: raw)) / 60)
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

    /// 処理枠で重い処理を一通り進める。**判断は `NightlyPlan.steps`（純ロジック・テスト対象）**で、
    /// ここは反映だけ（ADR-196）。
    ///
    /// 以前はこの関数が 142 行の直列手続きで、9 つの責務と `Task.isCancelled` の確認 4 か所を
    /// 抱え、テストが 1 本も無かった。窓の使い方は実機で繰り返し失敗している領域なので、
    /// 順序と条件は `NightlyPlan` に出してテストで固定する。
    private static func runHeavyWork() async {
        // 背面起動では scenePhase の変化が来ないことがあり、初期値（active）のままだと中央ゲートが
        // 開かない。処理枠の間は「背面」を明示して、前面の定期ループ（HomeView）に判断させない
        // （diagnostics-74）。
        // ⚠️ **スコープで入る**——以前は `isAppActive` / `isAppInBackground` を手で書き換え、
        // `restoreAppActive` という引数で後始末していた（戻し忘れがレビューで指摘されている）。
        await BackgroundYield.withScenePhase(.background) {
            // ストア群：プロセス内で唯一の共有インスタンス（前景 RootView と同じ）。別々に build すると
            // PeopleEngine/AutoAlbumEngine が二重化し顔/タグが二重起動するため必ず shared() を使う。
            let stores = await HomeStores.shared()
            Self.stores = stores
            guard !Task.isCancelled else { return }

            // ⚠️ 解析は**先に起こしてから**残りの手順を決める（レビュー指摘）。
            // 顔の残作業（`PeopleEngine.scanProgressRemaining`）はスキャン中しか更新されないので、
            // 起こす前に測ると必ず 0 になり、ADR-163 の「顔の残作業があるうちは生成を
            // 見送る」が永久に効かなくなる（生成と解析の共倒れ＝diagnostics-72 の再発）。
            let analysis = NightlyPlan.analysisStep(boostActive: stores.analysisSession.isActive)
            await perform(analysis, stores: stores)
            guard !Task.isCancelled else { return }

            let rest = NightlyPlan.remainingSteps(await gatherInputs(stores))
            RunTimeline.record("window plan: " + ([analysis] + rest).map(\.label).joined(separator: "→"))
            for step in rest {
                guard !Task.isCancelled else { break }
                await perform(step, stores: stores)
            }
            // ⚠️ **ここでバックアップを止めない**（レビュー 11 周目）。`Task.isCancelled` は
            // 期限切れでも**前面復帰でも**真になるので、ここで止めると
            // 「フォアグラウンド復帰では夜間バックアップを止めない」という決め
            // （`background-behavior.md`・`stopBackgroundProcessing` の `cancelBackup`）が
            // 実装されていないことになる——電話を手に取るだけで毎回中断していた。
            // しかも本体がここまで巻き戻るのは数十秒後になり得るので、その間に
            // **利用者が設定画面から始めたバックアップ**を横から止め得る。
            // 止めるべき経路（期限切れ・デバッグ実行の打ち切り）は
            // `stopBackgroundProcessing(cancelBackup: true)` で明示的に止めている。
        }
    }

    /// 判断の入力を測る（各値を読むのはここだけ）。
    private static func gatherInputs(_ stores: HomeStores) async -> NightlyPlan.Inputs {
        NightlyPlan.Inputs(
            boostActive: stores.analysisSession.isActive,
            embedBacklog: await stores.autoAlbumEngine.pendingEmbedCount(),
            // ⚠️ **`remaining` は使わない**（ADR-207）。`kick` は `.background` の Task を
            // 起こすだけで、`remaining` が書かれるのはスキャンの `onProgress`——`gatherInputs`
            // は `kick` の直後に走るので、新しい窓では**常に 0**だった（ADR-163 の修正が
            // 効いていなかった）。埋め込みが 0 で顔だけ残っている窓に生成が入り、
            // diagnostics-72 の共倒れが再発し得る。
            faceBacklog: stores.peopleEngine.faceBacklog ?? stores.peopleEngine.scanProgressRemaining,
            generateDeferrals: UserDefaults.standard.integer(forKey: AppSettingsKeys.generateDeferralStreak),
            maxGenerateDeferrals: maxGenerateDeferrals,
            availableMB: Int(MemoryBudget.availableBytes() / 1_048_576),
            networkAllowed: NetworkStateMonitor.shared.networkAllowed(),
            provideShareEnabled: ShareSettingsKeys.isProvideEnabled(),
            backupReconcileDue: stores.backupEngine.isReconcileDue(),
            publishAnalysisEnabled: ShareSettingsKeys.isPublishAnalysisEnabled())
    }

    /// 1 手を実行する。**ここに判断を書かない**（書くと窓を起こさないと確かめられなくなる）。
    private static func perform(_ step: NightlyPlan.Step, stores: HomeStores) async {
        switch step {
        case .startAnalysis:
            // 候補の列挙・消えた写真の掃除・顔スキャン・タグ/埋め込みは駆動役が持つ唯一の前口上。
            // 窓は特権時間なので、滞留した前面の実行を明け渡させてから始め直す（ADR-95）。
            await stores.analysisDriver.kick(.window)
        case .skipAnalysisBoostActive:
            Diagnostics.mark("bgtask: boost active — not starting analysis here")
        case .logStalledPasses:
            // 「動くべきなのに動いていない」パスを毎窓チェックして診断ログへ（ADR-87）。
            // 飢餓バグは沈黙として現れるため、こちらから沈黙を検出しにいく。
            await logStalledPasses(stores: stores)
        case .startBackup:
            stores.backupEngine.startNightlyIfEnabled()
        case .generate:
            UserDefaults.standard.set(0, forKey: AppSettingsKeys.generateDeferralStreak)
            await stores.autoAlbumEngine.refreshIfNeeded()
        case .deferGenerate(let streak):
            UserDefaults.standard.set(streak, forKey: AppSettingsKeys.generateDeferralStreak)
            Diagnostics.mark("bgtask: defer generate \(streak)/\(maxGenerateDeferrals)")
        case .skipGenerateLowMemory(let mb):
            // 見送りではなく「順番は来たが余裕が無い」なので、連続見送りの数は戻す。
            UserDefaults.standard.set(0, forKey: AppSettingsKeys.generateDeferralStreak)
            Diagnostics.mark("bgtask: skip generate (available=\(mb)MB)")
        case .shareImport:
            await stores.shareImporter.runIfNeeded()
        case .shareSync:
            // ADR-183 C: 共有セットを作成元（人物・AI アルバム）のいまのメンバーに追従させてから反映。
            await stores.shareEngine.refreshAllFromSource()
            await stores.shareEngine.syncNow()
        case .publishAnalysis:
            // 写真はコピーせず解析だけを置く（同じ Dropbox に繋いだだけの人にも届く・ADR-222）。
            await stores.analysisPublisher.runIfNeeded()
        case .reconcileBackup:
            // 実体が消えていても台帳は「済み」のままなので、放っておくと気づけない（ADR-166）。
            await stores.backupEngine.reconcileIfDueWeekly()
        case .drainUntilIdle:
            await drainUntilIdle(stores: stores)
        }
    }

    /// 残作業が続く限り待つ（期限切れ＝キャンセルで抜ける）。進捗はモニタで観測。
    private static func drainUntilIdle(stores: HomeStores) async {
        let monitor = BackgroundActivityMonitor.shared
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            let working = monitor.isEmbedding || monitor.isScanningFaces
                || monitor.embedRemaining > 0 || monitor.faceScanRemaining > 0
                || stores.backupEngine.isRunning
            if !working { break }   // 全部片付いた
        }
    }
}
