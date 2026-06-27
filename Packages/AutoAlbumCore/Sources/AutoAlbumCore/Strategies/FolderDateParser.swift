import Foundation

/// フォルダ名（Dropbox パスの一区切り）から日付を取り出す純パーサ（Foundation のみ・テスト対象）。
/// 多様な表記（ISO/区切り/圧縮/和暦/月名/範囲）を、粒度（年/月/日/範囲）つきの期間 [start, end] に正規化する。
/// 曖昧な数値日付（例 05/06/2023）は端末ロケールの月日順で解釈する。完全オフライン・通信なし。
public struct FolderDate: Sendable, Equatable {
    public enum Granularity: String, Sendable, Equatable { case year, month, day, range }
    public let start: Date
    public let end: Date
    public let granularity: Granularity

    public init(start: Date, end: Date, granularity: Granularity) {
        self.start = start
        self.end = end
        self.granularity = granularity
    }
}

public enum FolderDateParser {

    /// テキストから最初に解釈できた日付を返す。無ければ nil。
    public static func parse(_ text: String, calendar: Calendar = .current,
                             locale: Locale = .current, now: Date = Date()) -> FolderDate? {
        var cal = calendar
        cal.locale = locale

        // 1) 範囲（〜 ～ ~ – — / " to "）。両端が単一日付として解釈できれば range。
        for sep in ["〜", "～", "~", "–", "—", " to ", " 〜 ", " ～ "] {
            if let r = text.range(of: sep) {
                let lhs = String(text[..<r.lowerBound])
                let rhs = String(text[r.upperBound...])
                if let a = parseSingle(lhs, cal: cal, locale: locale, now: now),
                   let b = parseSingle(rhs, cal: cal, locale: locale, now: now) {
                    return FolderDate(start: min(a.start, b.start), end: max(a.end, b.end), granularity: .range)
                }
            }
        }
        // 2) 単一日付
        return parseSingle(text, cal: cal, locale: locale, now: now)
    }

    // MARK: - Single date

    private static func parseSingle(_ text: String, cal: Calendar, locale: Locale, now: Date) -> FolderDate? {
        let thisYear = cal.component(.year, from: now)

        // 年-月-日（区切り/和暦）: 2023-08-15, 2023/8/15, 2023.08.15, 2023年8月15日
        if let g = match(#"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?"#, text),
           let y = g[1], let m = g[2], let d = g[3], let r = dayRange(int(y), int(m), int(d), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .day)
        }
        // 圧縮8桁: 20230815
        if let g = match(#"(?<![0-9])(\d{4})(\d{2})(\d{2})(?![0-9])"#, text),
           let y = g[1], let m = g[2], let d = g[3], let r = dayRange(int(y), int(m), int(d), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .day)
        }
        // 月名（英）: "August 15, 2023" / "15 Aug 2023" / "Aug 2023" / "2023 Aug"
        if let fd = parseMonthName(text, cal: cal) { return fd }
        // 年-月（区切り/和暦）: 2023-08, 2023/8, 2023.08, 2023年8月
        if let g = match(#"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*月?"#, text),
           let y = g[1], let m = g[2], let r = monthRange(int(y), int(m), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .month)
        }
        // 圧縮6桁: 202308（月が 01-12 のときのみ＝4桁年の誤検出を避ける）
        if let g = match(#"(?<![0-9])(\d{4})(\d{2})(?![0-9])"#, text),
           let y = g[1], let m = g[2], (1...12).contains(int(m)), let r = monthRange(int(y), int(m), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .month)
        }
        // スラッシュ/ドットの曖昧日付（年が末尾4桁）: 15/08/2023, 08/15/2023, 05/06/2023
        if let g = match(#"(?<![0-9])(\d{1,2})[/.](\d{1,2})[/.](\d{4})(?![0-9])"#, text),
           let a = g[1], let b = g[2], let y = g[3] {
            let (m, d) = resolveAmbiguous(int(a), int(b), locale: locale)
            if let r = dayRange(int(y), m, d, cal) {
                return FolderDate(start: r.0, end: r.1, granularity: .day)
            }
        }
        // 年のみ: 2023, 2023年, "Hawaii 2023"（妥当範囲のみ）
        if let g = match(#"(?<![0-9])(\d{4})\s*年?(?![0-9])"#, text),
           let y = g[1], (1900...(thisYear + 1)).contains(int(y)), let r = yearRange(int(y), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .year)
        }
        return nil
    }

    // MARK: - Month names (English)

    private static let monthIndex: [String: Int] = {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
        var m: [String: Int] = [:]
        for (i, n) in names.enumerated() { m[n] = (n == "sept") ? 9 : i + 1 }
        return m
    }()

    private static func parseMonthName(_ text: String, cal: Calendar) -> FolderDate? {
        let mn = #"(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.?"#
        // 月名 + 日, 年: August 15, 2023 / Aug 15 2023
        if let g = match("\(mn)\\s+(\\d{1,2})\\s*,?\\s*(\\d{4})", text, caseInsensitive: true),
           let mo = g[1], let d = g[2], let y = g[3], let idx = monthIdx(mo),
           let r = dayRange(int(y), idx, int(d), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .day)
        }
        // 日 + 月名 + 年: 15 Aug 2023
        if let g = match("(\\d{1,2})\\s+\(mn)\\s*,?\\s*(\\d{4})", text, caseInsensitive: true),
           let d = g[1], let mo = g[2], let y = g[3], let idx = monthIdx(mo),
           let r = dayRange(int(y), idx, int(d), cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .day)
        }
        // 月名 + 年: Aug 2023 / August 2023
        if let g = match("\(mn)\\s*,?\\s*(\\d{4})", text, caseInsensitive: true),
           let mo = g[1], let y = g[2], let idx = monthIdx(mo), let r = monthRange(int(y), idx, cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .month)
        }
        // 年 + 月名: 2023 Aug
        if let g = match("(\\d{4})\\s+\(mn)", text, caseInsensitive: true),
           let y = g[1], let mo = g[2], let idx = monthIdx(mo), let r = monthRange(int(y), idx, cal) {
            return FolderDate(start: r.0, end: r.1, granularity: .month)
        }
        return nil
    }

    private static func monthIdx(_ s: String) -> Int? {
        let l = s.lowercased()
        if l.hasPrefix("sept") { return 9 }
        return monthIndex[String(l.prefix(3))]
    }

    // MARK: - Ambiguous order (locale)

    /// (a, b) を (month, day) に解決する。12 超で日と確定、両方 12 以下はロケールの月日順。
    static func resolveAmbiguous(_ a: Int, _ b: Int, locale: Locale) -> (month: Int, day: Int) {
        if a > 12 { return (b, a) }       // a は日
        if b > 12 { return (a, b) }       // b は日
        return monthBeforeDay(locale) ? (a, b) : (b, a)
    }

    /// ロケールが月→日順か（米=MDY:true、多くの欧=DMY:false、日=YMD だが M/d 部の順で判定）。
    static func monthBeforeDay(_ locale: Locale) -> Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "y/M/d"
        guard let mi = fmt.firstIndex(of: "M"), let di = fmt.firstIndex(of: "d") else { return true }
        return mi < di
    }

    // MARK: - Range builders

    private static func dayRange(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> (Date, Date)? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        guard let start = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        guard cal.component(.month, from: start) == m, cal.component(.day, from: start) == d else { return nil }  // Feb 30 等を弾く
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? start
        return (start, end)
    }

    private static func monthRange(_ y: Int, _ m: Int, _ cal: Calendar) -> (Date, Date)? {
        guard (1...12).contains(m), let start = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return nil }
        let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? start
        return (start, end)
    }

    private static func yearRange(_ y: Int, _ cal: Calendar) -> (Date, Date)? {
        guard let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) else { return nil }
        let end = cal.date(byAdding: DateComponents(year: 1, second: -1), to: start) ?? start
        return (start, end)
    }

    // MARK: - Regex helper（コンパイル結果をキャッシュ）

    /// パターン→コンパイル済み正規表現のキャッシュ。`NSCache` はスレッドセーフ。
    /// ※ 写真1枚ごとに同じパターンを毎回コンパイルすると 67k 件規模で処理が事実上停止するため必須。
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func compiled(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = ((caseInsensitive ? "i:" : "") + pattern) as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        regexCache.setObject(re, forKey: key)
        return re
    }

    /// 最初の一致のキャプチャ群を返す（index 0=全体, 1..=group）。無マッチ nil。
    private static func match(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> [String?]? {
        guard let re = compiled(pattern, caseInsensitive: caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func int(_ s: String) -> Int { Int(s) ?? 0 }
}
