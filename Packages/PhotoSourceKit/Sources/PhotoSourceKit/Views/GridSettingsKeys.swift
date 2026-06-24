import Foundation

/// グリッド表示の永続設定キー。`@AppStorage` の文字列リテラル散在を防ぐため一元管理する。
public enum GridSettingsKeys {
    /// ズーム段階（列数ラダーのインデックス）。ピンチとスライダーの共通の真実の源。
    public static let zoomLevel = "gridZoomLevel"
}
