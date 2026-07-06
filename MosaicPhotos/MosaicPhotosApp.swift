import MosaicSupport
import SwiftUI

@main
struct MosaicPhotosApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 未捕捉例外・メモリ圧迫を端末上の診断ログへ記録する（実機でも原因を追えるように）。
        Diagnostics.install()
        // アプリ内の言語設定（System/日本語/English）を起動時に反映する。
        AppLocale.loadFromDefaults()
        // パフォーマンス計測の永続トグル（Developer Options）を起動時に反映する。既定 OFF。
        PerfTrace.isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.perfTracing)
        // センサー: 起動（App.init）→ ホーム初回表示までの所要（endScreen は HomeView 側）。
        PerfTrace.beginScreen("app.startup")
        // BGProcessingTask（スクリーンロック中の重い処理）は launch 完了前の登録が必須。
        HeavyWorkScheduler.register()
        // B: 予約の保険（force-quit 後の復帰などで予約が消えていたら入れ直す）。
        HeavyWorkScheduler.submitIfMissing()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンド遷移（ロック含む）で次回の重い処理を予約する。
            // 電源接続が条件（requiresExternalPower）なので、電源が無い限り OS は起動しない。
            if phase == .background { HeavyWorkScheduler.submit() }
        }
    }
}
