#if canImport(UIKit)
import Foundation

/// 「場所（Places）」機能の永続設定キー。
public enum PlacesSettingsKeys {
    /// グルーピングのグリッド粒度（度）。小さいほど細かく分かれる。未設定時は `GeoGridKey.defaultStep`(0.02≈2km)。
    public static let gridStepDegrees = "placesGridStepDegrees"
    /// 場所の差分再スキャン間隔（秒）。未設定時は `defaultRescanIntervalSeconds`。
    public static let rescanIntervalSeconds = "placesRescanIntervalSeconds"
    /// `rescanIntervalSeconds` の既定値（秒）。
    public static let defaultRescanIntervalSeconds = 10
}
#endif
