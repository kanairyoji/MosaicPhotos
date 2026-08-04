import AutoAlbumCore
import BackgroundTasks
import BackupKit
import MosaicSupport
import SwiftUI

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
        // battery/unlimited 段階では電源なしでも夜間実行を許す（ユーザーの明示選択）。
        request.requiresExternalPower = HeavyWorkTiming.current < .battery       // 電源接続時のみ（ユーザー方針）
        request.requiresNetworkConnectivity = false // ローカル写真の処理は回線不要（クラウド分は回線ポリシーが弾く）
        do {
            try BGTaskScheduler.shared.submit(request)
            Diagnostics.mark("bgtask: submitted")
        } catch {
            // シミュレータ等では未サポートで失敗する（実害なし）。
            DiagnosticsLog.shared.append("bgtask: submit failed — \(error.localizedDescription)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        Diagnostics.mark("bgtask: begin")
        let started = Date()
        let work = Task { @MainActor in
            await runHeavyWork()
            Diagnostics.mark("bgtask: end (completed)")
            recordLastRun(started: started, outcome: "completed")
            task.setTaskCompleted(success: true)
            submit()   // 次回分を再予約（残作業はまた次のロック中に進む）
        }
        task.expirationHandler = {
            // OS の持ち時間切れ。各ループは Task.isCancelled で速やかに止まる。
            Diagnostics.mark("bgtask: expired — cancelling")
            work.cancel()
            Task { @MainActor in
                recordLastRun(started: started, outcome: "expired")
                task.setTaskCompleted(success: false)
                submit()
            }
        }
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
            await runHeavyWork()
            finish(outcome: "manual-completed")
        }
        // 時間制限（実 BG の期限切れを模擬）。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeLimit))
            if isDebugRunning {
                work.cancel()
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
    private static func runHeavyWork() async {
        // BGTask 実行中＝アプリは非アクティブ確定。バックグラウンド起動では scenePhase の
        // 変化が来ないことがあり、初期値（true）のままだと中央ゲートが開かない。
        BackgroundYield.isAppActive = false
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
        // 一時停止で滞留した既存タスクはゲートが開けば内部で自動再開する（真因の画像ロードハングは修正済み）。
        stores.peopleEngine.startScan(
            candidateRefKeys: await analysisOrderedRefKeys(dropboxStore: stores.dropboxStore),
            allowSimulator: allowSim)
        stores.autoAlbumEngine.scheduleBackgroundFill()

        // 1.5 バックアップ（ADR-42）: 宛先が Dropbox のとき、夜間ウィンドウで自動実行する。
        // 3-b: **AI（CLIP 埋め込み）の残作業が無い窓でだけ**開始する。両方ともメモリ/IO が重く、
        // 同一窓で同時に走らせるとピークが跳ねる。埋め込みが残る間はバックアップを見送り、AI が一巡した
        // 後の窓で回す（バックアップは差分から再開されるので遅延しても取りこぼさない）。
        let embedBacklog = await stores.autoAlbumEngine.pendingEmbedCount()
        if embedBacklog == 0 {
            stores.backupEngine.startNightlyIfEnabled()
        } else {
            Diagnostics.mark("bgtask: defer backup (embed backlog=\(embedBacklog))")
        }

        // 2. アルバム生成（差分があるときだけ・~26s 上限）。**顔/埋め込みを起こした後**に回す。
        // generate はピークが大きく（実測 ~550〜880MB）BG の厳しい jetsam 上限に触れてアプリごと
        // kill され、進捗が振り出しに戻る主因だった。残り許容量に**十分**な余裕がある時だけ実行する
        // （閾値を 700→900MB に引き上げ・Fix A）。余裕が無ければスキップし軽い処理だけ進める。
        let availableMB = MemoryBudget.availableBytes() / 1_048_576
        if availableMB > 900 {
            await stores.autoAlbumEngine.refreshIfNeeded()
        } else {
            Diagnostics.mark("bgtask: skip generate (available=\(availableMB)MB)")
        }
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
