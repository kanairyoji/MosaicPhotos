import Foundation
import Testing

/// パッケージの文字列が**カタログに載っていて、日本語がある**ことを静的に検査する（ADR-17）。
///
/// ⚠️ 実フィードバック「`Which of these are 名前` と英語で出る」。原因はカタログ移送の取り違えで、
/// **補間つきの文字列のキーをソースの見た目のまま**（`…“\(item.anchorName)”?`）保存していた。
/// 実行時のキーは**書式指定子**（`…“%@”?`）なので引けず、英語（base）へフォールバックしていた。
///
/// ⚠️ なぜ「実際に引いて」確かめないか: `swift test`（SwiftPM）では `.xcstrings` が Xcode の
/// ようにコンパイルされず、`Bundle.module` から日本語を引けない。実行時の照合では**常に英語が
/// 返る**ので、テストとして意味を持たない。だから**カタログの中身**を直接見る——
/// この失敗は「キーが無い」「訳が無い」のどちらかで、両方ここで捕まる。
@Suite("PeopleKit の文字列カタログ")
struct PeopleKitLocalizationTests {

    /// ソース内の `L("…")` を集める。
    private func sourceKeys() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PeopleKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // PeopleKit(package)
            .appendingPathComponent("Sources/PeopleKit")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var keys = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"L\("((?:[^"\\]|\\.)*)"\)"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for m in pattern.matches(in: text, range: range) {
                if let r = Range(m.range(at: 1), in: text) { keys.insert(String(text[r])) }
            }
        }
        return keys
    }

    /// `\(…)` を（入れ子の括弧ごと）`replacement` に置き換える。
    static func replacingInterpolations(in key: String, with replacement: String) -> String {
        var out = ""
        var index = key.startIndex
        while index < key.endIndex {
            guard key[index] == "\\", key.index(after: index) < key.endIndex,
                  key[key.index(after: index)] == "(" else {
                out.append(key[index]); index = key.index(after: index); continue
            }
            var depth = 0
            var cursor = key.index(after: index)   // "(" の位置
            while cursor < key.endIndex {
                if key[cursor] == "(" { depth += 1 }
                if key[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { cursor = key.index(after: cursor); break }
                }
                cursor = key.index(after: cursor)
            }
            out += replacement
            index = cursor
        }
        return out
    }

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PeopleKit/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    /// ソースの補間（`\(…)`）は実行時に**書式指定子**（`%@` / `%lld`）になる。その形で探す。
    ///
    /// ⚠️ **見た目どおりのキーを受け入れてはいけない**。今回のバグはまさにそれで、
    /// `…“\(item.anchorName)”?` というキーがカタログに在ったが、実行時に引かれるキーは
    /// `…“%@”?` なので一致せず英語になっていた。「在る」ではなく「**引ける形で**在る」を見る。
    private func resolves(_ key: String, in catalog: [String: Any]) -> String? {
        guard key.contains("\\(") else { return catalog[key] != nil ? key : nil }
        // ⚠️ 正規表現で `\(…)` を消さない。**入れ子の括弧**（`\(percent(x))`）があると
        // 最初の `)` で切れて照合できず、「カタログに無い」と誤判定する（実際に踏んだ）。
        // 括弧の深さを数えて 1 つの穴として飲み込む。
        let holePattern = Self.replacingInterpolations(in: key, with: "\u{1}")
        var regexSource = NSRegularExpression.escapedPattern(for: holePattern)
        regexSource = regexSource.replacingOccurrences(of: "\u{1}", with: "(%lld|%@|%d)")
        guard let rx = try? NSRegularExpression(pattern: "^" + regexSource + "$") else { return nil }
        return catalog.keys.first { candidate in
            rx.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }
    }

    @Test("ソースの文字列がすべてカタログに載っている")
    func everyStringIsInTheCatalog() throws {
        let keys = try sourceKeys(), cat = try catalog()
        #expect(!keys.isEmpty, "L(\"…\") を 1 つも拾えていない（検査自体が空振り）")
        let missing = keys.filter { resolves($0, in: cat) == nil }.sorted()
        if !missing.isEmpty { print("### カタログに無い:\n" + missing.joined(separator: "\n")) }
        #expect(missing.isEmpty, "カタログに無い文字列がある＝その画面は英語のまま出る（詳細は ### 行）")
    }

    @Test("すべての文字列に日本語がある")
    func everyStringHasJapanese() throws {
        let keys = try sourceKeys(), cat = try catalog()
        var untranslated: [String] = []
        for key in keys.sorted() {
            guard let resolved = resolves(key, in: cat),
                  let entry = cat[resolved] as? [String: Any],
                  let ja = (entry["localizations"] as? [String: Any])?["ja"] as? [String: Any]
            else { untranslated.append(key); continue }
            let hasValue = (ja["stringUnit"] as? [String: Any])?["value"] != nil || ja["variations"] != nil
            if !hasValue { untranslated.append(key) }
        }
        if !untranslated.isEmpty { print("### 日本語が無い:\n" + untranslated.joined(separator: "\n")) }
        #expect(untranslated.isEmpty, "日本語が無い文字列がある（詳細は ### 行）")
    }
}
