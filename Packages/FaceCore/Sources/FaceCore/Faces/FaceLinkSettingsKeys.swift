import Foundation

/// 埋め込み以外の証拠による連結（ADR-211/212）の設定キー。
///
/// ⚠️ キー文字列を読み手と書き手に重複させない（CLAUDE.md「設定キーの一元化」）。
public enum FaceLinkSettingsKeys {
    /// 服装（胴体）で繋ぐか。未設定は ON。
    public static let torsoLinking = "faceTorsoLinkingEnabled"
    /// 連写の位置で繋ぐか。未設定は ON。
    public static let burstLinking = "faceBurstLinkingEnabled"

    /// 未設定を ON とみなして読む。
    public static func isEnabled(_ key: String,
                                 defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
