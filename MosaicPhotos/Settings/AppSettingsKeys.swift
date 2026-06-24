import Foundation

/// アプリターゲット固有の設定キー（`@AppStorage` / `UserDefaults`）の一元定義。
/// パッケージ側のキーは各パッケージの専用 enum に集約する規約に合わせ、app 横断のキーはここへ。
enum AppSettingsKeys {
    /// Developer Options（詳細な診断・破壊的アクション）を表示するかどうか。既定 OFF。
    static let developerMode = "settings.developerMode"

    /// 詳細ログの抑制トグル。`MosaicSupport.LogChannel.verboseLoggingKey` と同一キー
    /// （app は MosaicSupport を直接 import しないため文字列で揃える）。
    static let verboseLogging = "debug.verboseLogging"
}
