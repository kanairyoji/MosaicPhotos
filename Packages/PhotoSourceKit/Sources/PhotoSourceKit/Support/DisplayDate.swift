import Foundation

/// アプリ全体の日付**表示**フォーマットを統一する（`YYYY-MM-DD` / `YYYY-MM` 等の数値表記）。
/// データ保存・API 用の日付（ISO8601 等）はここでは扱わない。
/// 数値表記なので固定ロケール（en_US_POSIX）で安定させる。
public enum DisplayDate {
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let ymdF = make("yyyy-MM-dd")
    private static let ymF = make("yyyy-MM")
    private static let yF = make("yyyy")
    private static let ymdHMF = make("yyyy-MM-dd HH:mm")

    /// `2026-06-18`
    public static func ymd(_ date: Date) -> String { ymdF.string(from: date) }
    /// `2026-06`
    public static func ym(_ date: Date) -> String { ymF.string(from: date) }
    /// `2026`
    public static func year(_ date: Date) -> String { yF.string(from: date) }
    /// `2026-06-18 14:30`（タイムスタンプ表示用）
    public static func dateTime(_ date: Date) -> String { ymdHMF.string(from: date) }

    /// 「意味のある撮影日時」だけを返す（無意味なら nil＝日時不明）。
    /// EXIF 欠落・0 値・カメラ既定値（1970/1980 等）で生じる無意味な日付を弾く。
    /// 1990-01-01 より前、または未来（+2日以上）を無意味とみなす。
    public static func meaningful(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let lower = Date(timeIntervalSince1970: 631_152_000)   // 1990-01-01 UTC
        let upper = Date(timeIntervalSinceNow: 2 * 86_400)
        return (date >= lower && date <= upper) ? date : nil
    }

    /// 日付範囲。同日なら単一、異なれば `2026-06-18 – 2026-06-20`。
    public static func range(_ start: Date, _ end: Date) -> String {
        let s = ymd(start)
        let e = ymd(end)
        return s == e ? s : "\(s) – \(e)"
    }
}
