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
    ///
    /// ⚠️⚠️ **正規表現で切り出さない**（2026-10-02 に踏んだ）。以前は
    /// `L\("((?:[^"\\]|\\.)*)"\)` で拾っていたが、**補間の中に文字列リテラルがあると拾えない**:
    /// ```swift
    /// L("Both already have names (\(names.joined(separator: " / "))). …")
    /// ```
    /// `separator: " / "` の `"` で切れるので、この 1 行だけ**検査から丸ごと消えていた**
    /// ——そしてその文字列は実際に**日本語が無く、実機で英語のまま出ていた**。
    /// 検査が「無い」と言わないのは、見ていないからだった。
    /// → 補間（`\(…)`）の括弧の深さと、その中の文字列リテラルを数えて歩く。
    ///
    /// ⚠️ 走査は**再帰**（`enumerator`）。以前は `contentsOfDirectory` で**直下だけ**だった
    /// ——いま `Sources/PeopleKit` にサブフォルダが無いので無害だったが、
    /// 1 つ作った日に黙って検査対象から外れる。
    private func sourceKeys() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PeopleKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // PeopleKit(package)
            .appendingPathComponent("Sources/PeopleKit")
        var files: [URL] = []
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        var keys = Set<String>()
        for file in files {
            keys.formUnion(Self.localizedKeys(in: try String(contentsOf: file, encoding: .utf8)))
        }
        return keys
    }

    /// `L("…")` の中身を取り出す（補間の中の `"` と入れ子の括弧を飲み込む）。純ロジック・テスト対象。
    static func localizedKeys(in text: String) -> Set<String> {
        var out = Set<String>()
        let chars = Array(text)
        var i = 0
        while i + 2 < chars.count {
            // `L("` の始まり。⚠️ 直前が識別子の一部なら別の関数（例 `URL(`）。
            guard chars[i] == "L", chars[i + 1] == "(", chars[i + 2] == "\"" else { i += 1; continue }
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" {
                i += 1; continue
            }
            var j = i + 3
            var depth = 0          // 補間 `\(` の深さ
            var body = ""
            var closed = false
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count {
                    if chars[j + 1] == "(" { depth += 1; body += "\\("; j += 2; continue }
                    body.append(c); body.append(chars[j + 1]); j += 2; continue
                }
                if depth > 0 {
                    // 補間の中。文字列リテラルは丸ごと飲み込む（ここが以前の穴）。
                    if c == "\"" {
                        body.append(c); j += 1
                        while j < chars.count, chars[j] != "\"" {
                            if chars[j] == "\\", j + 1 < chars.count { body.append(chars[j]); j += 1 }
                            body.append(chars[j]); j += 1
                        }
                        if j < chars.count { body.append(chars[j]); j += 1 }
                        continue
                    }
                    if c == "(" { depth += 1 }
                    if c == ")" { depth -= 1 }
                    body.append(c); j += 1; continue
                }
                if c == "\"" { closed = true; break }   // 文字列の終わり
                body.append(c); j += 1
            }
            if closed { out.insert(body) }
            i = max(j, i + 1)
        }
        return out
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
    /// ⚠️⚠️ **当たるキーを「1 つ」返してはいけない**（2026-10-02 に CI が落ちて気づいた）。
    /// 以前は `catalog.keys.first { … }` だったが、`Int` の補間は実行時に `%lld` にも `%d` にも
    /// なり得るので**同じ穴に当たるキーが複数カタログに載る**ことがある
    /// （実機のカタログに `%d photos`（訳あり）と `%lld photos`（訳なし）が両方居た）。
    /// `Dictionary.keys` の順序は**プロセスごとに変わる**（Hasher の種）ので、
    /// どちらを引くかは実行ごとのくじ——**同じコードで通る回と落ちる回があった**。
    /// しかも落ちた回が正しくて、`%lld photos` は実機で英語のまま出ていた。
    /// → **当たる全部**を返し、呼び手は「全部に訳がある」ことを要求する。
    ///   どれが実行時のキーになるかソースからは決められないので、安全側はこちら。
    private func resolvedKeys(_ key: String, in catalog: [String: Any]) -> [String] {
        guard key.contains("\\(") else { return catalog[key] != nil ? [key] : [] }
        // ⚠️ 正規表現で `\(…)` を消さない。**入れ子の括弧**（`\(percent(x))`）があると
        // 最初の `)` で切れて照合できず、「カタログに無い」と誤判定する（実際に踏んだ）。
        // 括弧の深さを数えて 1 つの穴として飲み込む。
        let holePattern = Self.replacingInterpolations(in: key, with: "\u{1}")
        var regexSource = NSRegularExpression.escapedPattern(for: holePattern)
        regexSource = regexSource.replacingOccurrences(of: "\u{1}", with: "(%lld|%@|%d)")
        guard let rx = try? NSRegularExpression(pattern: "^" + regexSource + "$") else { return [] }
        // ⚠️ 並べ替えて返す（報告が実行ごとに入れ替わらないように）。
        return catalog.keys.filter { candidate in
            rx.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }.sorted()
    }

    /// そのカタログ項目に日本語があるか（`stringUnit` でも複数形の `variations` でもよい）。
    static func hasJapanese(_ entry: Any?) -> Bool {
        guard let entry = entry as? [String: Any],
              let ja = (entry["localizations"] as? [String: Any])?["ja"] as? [String: Any]
        else { return false }
        return (ja["stringUnit"] as? [String: Any])?["value"] != nil || ja["variations"] != nil
    }

    @Test("ソースの文字列がすべてカタログに載っている")
    func everyStringIsInTheCatalog() throws {
        let keys = try sourceKeys(), cat = try catalog()
        #expect(!keys.isEmpty, "L(\"…\") を 1 つも拾えていない（検査自体が空振り）")
        let missing = keys.filter { resolvedKeys($0, in: cat).isEmpty }.sorted()
        if !missing.isEmpty { print("### カタログに無い:\n" + missing.joined(separator: "\n")) }
        #expect(missing.isEmpty, "カタログに無い文字列がある＝その画面は英語のまま出る（詳細は ### 行）")
    }

    @Test("すべての文字列に日本語がある")
    func everyStringHasJapanese() throws {
        let keys = try sourceKeys(), cat = try catalog()
        var untranslated: [String] = []
        for key in keys.sorted() {
            let resolved = resolvedKeys(key, in: cat)
            if resolved.isEmpty { untranslated.append(key); continue }
            // ⚠️ **当たるキー全部**に訳が要る。どれが実行時のキーになるかはソースから決まらない
            //    （`Int` は `%lld` にも `%d` にもなり得る）ので、1 つでも欠けていれば未翻訳扱い。
            for name in resolved where !Self.hasJapanese(cat[name]) {
                untranslated.append("\(key)   ← カタログの \(name) に訳が無い")
            }
        }
        if !untranslated.isEmpty { print("### 日本語が無い:\n" + untranslated.joined(separator: "\n")) }
        #expect(untranslated.isEmpty, "日本語が無い文字列がある（詳細は ### 行）")
    }

    // MARK: - 検査そのもののテスト（2026-10-02）

    /// ⚠️⚠️ **検査が「見ていない」ことを、検査では気づけない**。
    /// 以前の切り出しは正規表現で、**補間の中に文字列リテラルがあると拾えなかった**
    /// ——`separator: " / "` の `"` で切れる。その 1 行が丸ごと検査から消え、
    /// **実機で英語のまま出ていた**のに「未翻訳なし」と報告していた。
    /// だから切り出し自体にテストを置く（カタログの状態に依存しない）。
    @Test("補間の中に文字列リテラルがあっても拾える（以前はここで切れていた）")
    func scannerHandlesStringLiteralsInsideInterpolation() {
        let source = ##"""
        Text(L("Both already have names (\(choice.names.joined(separator: " / "))). Stop here."))
        """##
        let expected = ##"Both already have names (\(choice.names.joined(separator: " / "))). Stop here."##
        #expect(PeopleKitLocalizationTests.localizedKeys(in: source) == [expected],
                "拾えていない（以前の正規表現と同じ穴が空いている）")
    }

    @Test("入れ子の括弧を飲み込む")
    func scannerHandlesNestedParens() {
        let keys = PeopleKitLocalizationTests.localizedKeys(in: ##"L("\(percent(of: x)) done")"##)
        #expect(keys == [##"\(percent(of: x)) done"##])
    }

    @Test("ふつうの文字列・複数・エスケープ")
    func scannerHandlesOrdinaryCases() {
        let source = ##"""
        a = L("Hello"); c = L("\(n) photos")
        """##
        #expect(PeopleKitLocalizationTests.localizedKeys(in: source)
                == ["Hello", ##"\(n) photos"##])
    }

    /// ⚠️ `L(` で終わる別の識別子（`XL(` 等）を拾わない。
    @Test("別の関数の L で終わる名前は拾わない")
    func scannerIgnoresOtherFunctions() {
        #expect(PeopleKitLocalizationTests.localizedKeys(in: ##"XL("nope")"##).isEmpty)
        #expect(PeopleKitLocalizationTests.localizedKeys(in: ##"myL("nope")"##).isEmpty)
    }

    /// ⚠️⚠️ **当たるキーが複数あるときは全部に訳が要る**（CI が実行ごとに通る／落ちる原因だった）。
    /// `Int` の補間は実行時に `%lld` にも `%d` にもなり得るので、カタログに両方載ることがある。
    /// 以前は `catalog.keys.first` で**くじ引き**になっていた——`Dictionary.keys` の順序は
    /// プロセスごとに変わる（Hasher の種）ので、同じコードで通る回と落ちる回があった。
    @Test("同じ穴に当たるキーが複数あれば、全部を見る")
    func resolvesEveryMatchingCatalogKey() throws {
        let cat = try catalog()
        let resolved = resolvedKeys(##"\(n) photos"##, in: cat)
        #expect(resolved.count >= 2, """
            fixture: このカタログには `%d photos` と `%lld photos` が両方居るはず
            （居なくなったらこのテストは何も見ていない）: \(resolved)
            """)
        for name in resolved {
            #expect(PeopleKitLocalizationTests.hasJapanese(cat[name]),
                    "\(name) に日本語が無い（実行時にこのキーが引かれたら英語のまま出る）")
        }
    }
}
