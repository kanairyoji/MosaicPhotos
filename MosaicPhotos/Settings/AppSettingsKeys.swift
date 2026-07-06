import Foundation

/// アプリターゲット固有の設定キー（`@AppStorage` / `UserDefaults`）の一元定義。
/// パッケージ側のキーは各パッケージの専用 enum に集約する規約に合わせ、app 横断のキーはここへ。
enum AppSettingsKeys {
    /// 詳細ログの抑制トグル。`MosaicSupport.LogChannel.verboseLoggingKey` と同一キー
    /// （app は MosaicSupport を直接 import しないため文字列で揃える）。
    static let verboseLogging = "debug.verboseLogging"
    /// パフォーマンス計測（`MosaicSupport.PerfTrace.isEnabled`）の永続トグル。
    /// 起動時にこの値で `PerfTrace.isEnabled` を初期化し、Developer Options で実機 ON/OFF できる。
    static let perfTracing = "debug.perfTracing"
    /// ピープルの顔スキャンをシミュレータでも走らせる（既定 OFF）。デバッグ用。
    /// 顔モデルは cpuOnly で遅いが動作はするので、実機が無いときの動作確認に使う。
    static let faceScanOnSimulator = "debug.faceScanOnSimulator"
    /// D: BGProcessingTask の最終実行記録（開始時刻・結果・所要分。Developer Options で表示）。
    static let bgTaskLastRun = "debug.bgTaskLastRun"
}
