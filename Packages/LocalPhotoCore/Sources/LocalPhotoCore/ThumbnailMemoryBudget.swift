import Foundation

/// ローカルサムネイルのメモリ上限を解決するヘルパー。
///
/// 設定値（`CacheSettingsKeys.memoryLimitMB`）の **0 は「Auto」** を意味し、端末の物理 RAM に
/// 応じた控えめな予算を自動算出する（低 RAM 端末は軽く、高 RAM 端末は少し余裕を持たせる）。
/// 0 以外はその MB 値をそのまま使う。
public enum ThumbnailMemoryBudget {

    /// 設定 MB（0=Auto）から実効バイト数を求める。
    public static func effectiveBytes(forSettingMB settingMB: Int) -> Int {
        settingMB > 0 ? settingMB * 1024 * 1024 : autoBytes()
    }

    /// Auto 時の上限バイト数：物理 RAM の約 1.5%、40MB〜120MB にクランプ。
    public static func autoBytes() -> Int {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)   // bytes
        let budget = ram * 0.015
        let floor = 40 * 1024 * 1024
        let ceil = 120 * 1024 * 1024
        return min(max(Int(budget), floor), ceil)
    }

    /// Auto 時の概算 MB（設定 UI の説明表示用）。
    public static func autoMB() -> Int { autoBytes() / (1024 * 1024) }
}
