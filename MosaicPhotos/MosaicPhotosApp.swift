import MosaicSupport
import SwiftUI

@main
struct MosaicPhotosApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// 背景 URLSession の完了イベント（ADR-181）を受けるためだけの delegate。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 未捕捉例外・メモリ圧迫を端末上の診断ログへ記録する（実機でも原因を追えるように）。
        Diagnostics.install()
        // アプリ内の言語設定（System/日本語/English）を起動時に反映する。
        AppLocale.loadFromDefaults()
        // 旧 5 段階の処理タイミング設定を 4 軸（自動処理/控えめ/電源/回線）へ移行する（ADR-80・1 度だけ）。
        HeavyWorkTiming.migrateLegacySettingsIfNeeded()
        // パフォーマンス計測の永続トグル（Developer Options）を起動時に反映する。既定 OFF。
        PerfTrace.isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.perfTracing)
        // センサー: 起動（App.init）→ ホーム初回表示までの所要（endScreen は HomeView 側）。
        PerfTrace.beginScreen("app.startup")
        // BGProcessingTask（スクリーンロック中の重い処理）は launch 完了前の登録が必須。
        HeavyWorkScheduler.register()
        // B: 予約の保険（force-quit 後の復帰などで予約が消えていたら入れ直す）。
        HeavyWorkScheduler.submitIfMissing()
        // ⚠️ **動いていなかった時間について、動き出した瞬間に分かることを全部書く**（diagnostics-81）。
        //    前回の終わり方（正常／窓の途中＝iOS に終了させられた疑い）・いまの端末条件・
        //    OS に積まれている予約。これが無かったので「12 時間 窓が来なかった」の理由を
        //    実機ログから特定できなかった。
        RunTimeline.record("launch — \(appVersionLine()) " + HeavyWorkScheduler.environmentLine())
        if let previous = RunTimeline.previousRunSummary() { RunTimeline.record("前回: \(previous)") }
        RunTimeline.noteState("idle")
        HeavyWorkScheduler.logPendingRequests(context: "launch")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { BackgroundYield.isAppActive = (scenePhase == .active) }
        }
        .onChange(of: scenePhase) { _, phase in
            // 重い処理の中央ゲート: アクティブ（＝ユーザーが操作中）の間は一切動かさない。
            // 画面ロック/アプリ切替（inactive/background）で解放される（実行の主役は BGTask）。
            BackgroundYield.isAppActive = (phase == .active)
            BackgroundYield.isAppInBackground = (phase == .background)
            // D: 遷移の実測（復帰時に何が走っていたか）を診断ログへ 1 行残す。
            HeavyWorkScheduler.noteScenePhase("\(phase)")
            // ADR-79: 復帰したら夜間処理を**明示的に止める**。ゲートを閉じるだけでは、実行中の
            // 1 単位が走り切るまで ANE/CPU が塞がり、眠っている間もモデルを抱え続けて
            // カクつきの原因になっていた。
            if phase == .active {
                HeavyWorkScheduler.stopForForeground()
                // 中断された解析セッションを自動で再開する（diagnostics-81）。
                // ロック（iOS の既知の問題）・OS の期限切れ・プロセス終了でセッションは消えるが、
                // 「押した」という事実は永続化してあるので、戻ってきたら続きから再開する。
                Task { @MainActor in await HeavyWorkScheduler.stores?.analysisSession.resumeIfPending() }
            }
            // バックグラウンド遷移（ロック含む）で次回の重い処理を予約する。
            // 電源接続が条件（requiresExternalPower）なので、電源が無い限り OS は起動しない。
            if phase == .background { HeavyWorkScheduler.submit() }
        }
    }
}
