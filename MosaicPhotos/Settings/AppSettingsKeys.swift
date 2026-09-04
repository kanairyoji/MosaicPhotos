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
    /// 解析（顔・埋め込み）の残作業を理由にアルバム生成を**連続で見送った回数**。
    /// 上限に達したら残っていても生成へ窓を明け渡す（`HeavyWorkScheduler`・飢餓防止）。
    static let generateDeferralStreak = "generate.deferralStreak"
    /// キャプションが顔スキャンに譲り続けた回数（ADR-86・上限で「キャプション窓」にする）。
    // ※ 旧 `captionDeferralStreak`（"caption.deferralStreak"）は VLM 廃止で撤去（ADR-108）。
    /// この端末で解析が始まり得た時刻（ADR-87・停滞検出の基準。未実行パスの誤検知を防ぐ）。
    static let firstLaunchAt = "analysis.firstLaunchAt"
}
