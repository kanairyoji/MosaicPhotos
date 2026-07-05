import AutoAlbumCore
import BackgroundTasks
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
    static let taskID = "com.kanai.MosaicPhotos.heavywork"

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

    /// バックグラウンド遷移時に次回実行を予約する。電源接続が条件（OS が満たされるまで起動しない）。
    static func submit() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true       // 電源接続時のみ（ユーザー方針）
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
        let work = Task { @MainActor in
            await runHeavyWork()
            Diagnostics.mark("bgtask: end (completed)")
            task.setTaskCompleted(success: true)
            submit()   // 次回分を再予約（残作業はまた次のロック中に進む）
        }
        task.expirationHandler = {
            // OS の持ち時間切れ。各ループは Task.isCancelled で速やかに止まる。
            Diagnostics.mark("bgtask: expired — cancelling")
            work.cancel()
            Task { @MainActor in
                task.setTaskCompleted(success: false)
                submit()
            }
        }
    }

    /// 重い処理を一通り進める。フォアグラウンドと同じゲート（heavyShouldPause）を通るが、
    /// BG 中は操作が発生しないためアイドル条件は自然に満たされる。
    private static func runHeavyWork() async {
        // ストア群：フォアグラウンドの生き残りを再利用、無ければ（BG からのプロセス再起動）構築。
        let stores: HomeStores
        if let existing = Self.stores {
            stores = existing
        } else {
            stores = await HomeStores.build()
            Self.stores = stores
        }
        if Task.isCancelled { return }

        // 1. アルバム生成（差分があるときだけ・~26s 上限・キャンセル非対応だが有界）。
        await stores.autoAlbumEngine.refreshIfNeeded()
        if Task.isCancelled { return }

        // 2. 顔スキャン＋CLIP 埋め込みを開始（それぞれ内部でトリクル実行・1枚ごとに譲り判定）。
        stores.peopleEngine.startScan(candidateRefKeys: await localImageRefKeys())
        stores.autoAlbumEngine.scheduleBackgroundFill()

        // 3. 残作業が続く限り待つ（期限切れ＝キャンセルで抜ける）。進捗はモニタで観測。
        let monitor = BackgroundActivityMonitor.shared
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            let working = monitor.isEmbedding || monitor.isScanningFaces
                || monitor.embedRemaining > 0 || monitor.faceScanRemaining > 0
            if !working { break }   // 全部片付いた
        }
    }
}
