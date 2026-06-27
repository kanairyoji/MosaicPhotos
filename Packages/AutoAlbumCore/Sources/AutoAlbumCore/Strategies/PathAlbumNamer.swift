import Foundation

/// パス文字列を `PathAlbumRule` 群でアルバム名へ変換する純ロジック（Foundation のみ・テスト対象）。
/// 上から評価し最初にマッチしたルールの結果を返す。無マッチは nil（＝意味のないパスとして除外）。
public enum PathAlbumNamer {

    /// パスからアルバム名を抽出。最初にマッチしたルールの整形済み名前。無マッチは nil。
    public static func name(forPath path: String, rules: [PathAlbumRule], normalize: Bool = true) -> String? {
        for rule in rules {
            if let name = apply(rule, to: path, normalize: normalize) { return name }
        }
        return nil
    }

    /// 設定プレビュー用：マッチしたルール番号（0始まり）と抽出名。
    public static func preview(path: String, rules: [PathAlbumRule], normalize: Bool = true) -> (index: Int, name: String)? {
        for (i, rule) in rules.enumerated() {
            if let name = apply(rule, to: path, normalize: normalize) { return (i, name) }
        }
        return nil
    }

    /// 正規表現として妥当か（設定入力のバリデーション用）。
    public static func isValidPattern(_ pattern: String) -> Bool {
        !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    // MARK: - Private

    /// パターン→コンパイル済み正規表現のキャッシュ（写真ごとの再コンパイルを避ける。67k 規模で必須）。
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func compiled(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = ((caseInsensitive ? "i:" : "") + pattern) as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        regexCache.setObject(re, forKey: key)
        return re
    }

    private static func apply(_ rule: PathAlbumRule, to path: String, normalize: Bool) -> String? {
        guard !rule.pattern.isEmpty,
              let regex = compiled(rule.pattern, caseInsensitive: rule.caseInsensitive)
        else { return nil }
        let ns = path as NSString
        guard let match = regex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = substitute(template: rule.template, match: match, in: ns)
        let result = normalize ? normalized(raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// テンプレートのキャプチャ参照（`${name}` / `$1` / `$$`）を展開する。
    private static func substitute(template: String, match: NSTextCheckingResult, in ns: NSString) -> String {
        func numbered(_ idx: Int) -> String {
            guard idx >= 0, idx < match.numberOfRanges else { return "" }
            let r = match.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        func named(_ name: String) -> String {
            let r = match.range(withName: name)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }

        let chars = Array(template)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "$" else { out.append(chars[i]); i += 1; continue }
            if i + 1 < chars.count, chars[i + 1] == "$" {            // $$ → リテラル $
                out.append("$"); i += 2; continue
            }
            if i + 1 < chars.count, chars[i + 1] == "{" {            // ${name}
                var j = i + 2
                var name = ""
                while j < chars.count, chars[j] != "}" { name.append(chars[j]); j += 1 }
                if j < chars.count { out.append(named(name)); i = j + 1; continue }
            }
            var j = i + 1                                            // $<digits>
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if let idx = Int(digits) { out.append(numbered(idx)); i = j; continue }
            out.append("$"); i += 1                                  // 単独の $
        }
        return out
    }

    /// 軽い整形：`_` と単語区切りの `-` を空白に、連続空白を1つに、トリム。
    /// ただし**日付内のハイフン（数字-数字）は残す**（例 `2025-10-05` はそのまま）。
    /// 日本語を含む任意の UTF-8 文字をそのまま許可する（長さで弾かない）。空白のみは空扱い。
    private static func normalized(_ s: String) -> String {
        let underscored = s.replacingOccurrences(of: "_", with: " ")
        // 数字に挟まれていないハイフンだけ空白へ（日付 2025-10-05 のハイフンは温存）。
        let spaced: String
        if let re = compiled(#"(?<![0-9])-|-(?![0-9])"#, caseInsensitive: false) {
            let ns = underscored as NSString
            spaced = re.stringByReplacingMatches(
                in: underscored, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        } else {
            spaced = underscored.replacingOccurrences(of: "-", with: " ")
        }
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
