import Foundation

/// 自然文の相対・暦表現 → `AIAlbumDateRange` の純パーサ（日英・テスト対象）。
/// Foundation Models 非対応端末や誤判定の保険として `RuleBasedQueryUnderstanding` から使う。
/// 日付演算自体は `AIAlbumDateRange.resolved(now:)` が現在日時から確定する（ここでは種別と N だけ決める）。
public enum RelativeDateParser {

    /// 最初に一致した日付表現を返す。無ければ nil。
    public static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> AIAlbumDateRange? {
        let lower = text.lowercased()
        let year = calendar.component(.year, from: now)

        // --- 暦の固定表現（先に判定：相対 N より具体的） ---
        if text.contains("一昨年") { return .year(year - 2) }
        if text.contains("去年") || text.contains("昨年") || lower.contains("last year") { return .year(year - 1) }
        if text.contains("今年") || lower.contains("this year") { return .year(year) }

        // 「N年前」→ その暦年（点ではなくその年）
        if let n = firstInt(lower, #"(\d+)\s*年前"#) { return .year(year - n) }

        // --- 相対レンジ（ここ/過去/直近/最近/last/past + N + 単位） ---
        // 年
        if let n = firstInt(lower, #"(?:ここ|この|過去|直近|最近)\s*(\d+)\s*年"#)
            ?? firstInt(lower, #"(?:last|past|recent)\s+(\d+)\s*years?"#) {
            return .lastYears(max(1, n))
        }
        // 月（ヶ月/か月/カ月/箇月/ケ月/months）
        if let n = firstInt(lower, #"(?:ここ|この|過去|直近|最近)\s*(\d+)\s*(?:ヶ月|か月|カ月|箇月|ケ月|ヵ月)"#)
            ?? firstInt(lower, #"(?:last|past|recent)\s+(\d+)\s*months?"#) {
            return .lastMonths(max(1, n))
        }
        // 半年
        if text.contains("半年") || lower.contains("half a year") { return .lastMonths(6) }
        // 日
        if let n = firstInt(lower, #"(?:ここ|この|過去|直近|最近)\s*(\d+)\s*日"#)
            ?? firstInt(lower, #"(?:last|past|recent)\s+(\d+)\s*days?"#) {
            return .lastDays(max(1, n))
        }
        // 「最近」「recently」（数値なし）→ 直近30日
        if text.contains("最近") || lower.contains("recently") { return .lastDays(30) }

        // --- 西暦4桁（相対が無いときの保険） ---
        if let y = firstInt(text, #"((?:19|20)\d{2})"#) { return .year(y) }

        return nil
    }

    /// パターンの最初のキャプチャ（無ければ全体）を Int で返す。
    static func firstInt(_ text: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let idx = m.numberOfRanges > 1 ? 1 : 0
        let r = m.range(at: idx)
        guard r.location != NSNotFound else { return nil }
        return Int(ns.substring(with: r))
    }
}
