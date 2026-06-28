import Foundation

/// グリッド表示の永続設定キー。`@AppStorage` の文字列リテラル散在を防ぐため一元管理する。
public enum GridSettingsKeys {
    /// ズーム段階（列数ラダーのインデックス）。ピンチとスライダーの共通の真実の源。
    public static let zoomLevel = "gridZoomLevel"
    /// 月グループの密度＝1セクションを閉じる前に貯める**行数**（1/3/5…）。大きいほど
    /// 見出し（範囲ラベル）が減って粗く・密になる。既定 1（1行ぶんで閉じる＝現状の最大密度）。
    public static let monthSectionRows = "gridMonthSectionRows"
}
