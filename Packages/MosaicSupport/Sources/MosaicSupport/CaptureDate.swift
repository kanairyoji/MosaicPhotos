import Foundation

/// 撮影日時のサニタイズ共通判定。EXIF 欠落・0 値・カメラ既定値（1970/1980 等）・未来日を
/// 「日時不明（nil）」へ落とす。**表示層だけでなくデータの入口**（`LocalPhotoItem` /
/// `DropboxFileItem` 生成点 / `PhotoEnricher`）で使うことで、ソート・自動アルバム生成・
/// 場所スキャンにも無意味な日付が混ざらないようにする（ADR 参照）。
public enum CaptureDate {
    /// 有効とみなす下限（1990-01-01 UTC）。スマホ/デジタル写真でこれより古い正当な日付はまず無い。
    private static let lowerBound = Date(timeIntervalSince1970: 631_152_000)

    /// 「意味のある撮影日時」だけを返す（無意味なら nil＝日時不明）。
    /// 1990-01-01 より前、または未来（+2日以上）を無意味とみなす。
    public static func meaningful(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let upper = Date(timeIntervalSinceNow: 2 * 86_400)
        return (date >= lowerBound && date <= upper) ? date : nil
    }
}
