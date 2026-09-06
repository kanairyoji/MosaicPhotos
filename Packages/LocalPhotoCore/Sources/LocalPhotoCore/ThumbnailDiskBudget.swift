import Foundation

/// 端末写真サムネのディスクキャッシュ上限（設定 0＝Auto）。
///
/// 以前の既定は 500MB 固定で、選択肢も 2GB まで。1 枚 20〜40KB のサムネで 500MB は 1.5 万枚ぶんに
/// しかならず、8 万枚のライブラリではグリッドを往復するたびに捨てて作り直していた。
/// ディスクは RAM と違って余裕があるので、**容量の 10%** を既定にし、ユーザーが変えられるようにする
/// （実フィードバック）。上限を上げても、使うのは実際にスクロールして生成した分だけ。
public enum ThumbnailDiskBudget {

    /// Auto の割合（端末の総容量に対して）。
    public static let autoFraction = 0.10
    public static let autoFloor = 500 * 1024 * 1024
    public static let autoCeil = 50 * 1024 * 1024 * 1024

    /// 設定 MB（0=Auto）から実効バイト数を求める。
    public static func effectiveBytes(forSettingMB settingMB: Int) -> Int {
        settingMB > 0 ? settingMB * 1024 * 1024 : autoBytes()
    }

    /// Auto 時の上限バイト数: 端末の総容量の 10%（500MB〜50GB にクランプ）。
    public static func autoBytes(totalCapacity: Int? = nil) -> Int {
        let total = totalCapacity ?? volumeTotalCapacity() ?? 0
        return autoBytes(fromTotal: total)
    }

    /// 純ロジック（テスト対象）。総容量が読めない（0）ときは下限。
    public static func autoBytes(fromTotal total: Int) -> Int {
        guard total > 0 else { return autoFloor }
        return min(max(Int(Double(total) * autoFraction), autoFloor), autoCeil)
    }

    /// 端末の総容量（Caches のあるボリューム）。
    static func volumeTotalCapacity() -> Int? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let values = try? caches.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity
    }
}
