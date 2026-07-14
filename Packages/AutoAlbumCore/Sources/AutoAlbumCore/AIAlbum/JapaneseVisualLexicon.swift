import Foundation

/// 日本語の頻出**視覚語**と否定パターンの決定的レキシコン（純・テスト対象）。
///
/// FM（翻訳・解釈）はシミュレータ/非対応端末で失敗し得るし、小型 LLM の構造化出力は
/// 壊れ得る（実障害多数）。RelativeDateParser（日付）と同じ思想で、**よく使う視覚概念と
/// 人物否定だけは決定的に抽出**し、LLM ゼロでもタグ照合・除外・証拠ゲートが機能するようにする。
/// 網羅は目的でない（LLM が動くときは LLM が上書きする補助線）。
public enum JapaneseVisualLexicon {

    /// 日本語の視覚語 → 英語タグ語（Vision 分類・CLIP と照合できる語）。
    private static let visualWords: [(jp: [String], en: [String])] = [
        (["風景", "景色"], ["landscape", "scenery", "outdoor"]),
        (["子供", "子ども", "こども"], ["child", "children"]),
        (["赤ちゃん", "乳児"], ["baby", "infant"]),
        (["家族"], ["family"]),
        (["犬"], ["dog"]),
        (["猫"], ["cat"]),
        (["動物"], ["animal"]),
        (["鳥"], ["bird"]),
        (["海", "ビーチ", "浜辺"], ["beach", "sea", "ocean"]),
        (["山"], ["mountain"]),
        (["川"], ["river"]),
        (["空"], ["sky"]),
        (["雪"], ["snow"]),
        (["花"], ["flower"]),
        (["桜"], ["cherry blossom"]),
        (["紅葉"], ["autumn leaves", "foliage"]),
        (["夕日", "夕焼け", "日没"], ["sunset"]),
        (["夜景", "夜"], ["night"]),
        (["食べ物", "料理", "ごはん", "食事"], ["food", "meal"]),
        (["ケーキ"], ["cake"]),
        (["車", "クルマ"], ["car"]),
        (["電車", "列車"], ["train"]),
        (["飛行機"], ["airplane"]),
        (["建物", "建築"], ["building", "architecture"]),
        (["神社", "寺", "お寺"], ["shrine", "temple"]),
        (["公園"], ["park"]),
        (["花火"], ["fireworks"]),
        (["結婚式"], ["wedding"]),
        (["誕生日"], ["birthday"]),
        (["プール"], ["pool", "swimming"]),
        (["富士山"], ["mount fuji", "mountain"]),
    ]

    /// 人物の否定（「人が写っていない」等）のパターン。
    private static let peopleNegations = [
        "人が写っていない", "人がいない", "人物なし", "人なし", "誰もいない", "無人",
        "without people", "no people", "nobody", "without any people",
    ]

    /// 原文から視覚語（英語）を決定的に抽出する。見つからなければ空。
    static func includeTerms(in criteria: String) -> [String] {
        let lower = criteria.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        for entry in visualWords where entry.jp.contains(where: { criteria.contains($0) || lower.contains($0) }) {
            for en in entry.en where seen.insert(en).inserted { out.append(en) }
        }
        return out
    }

    /// 入力に含まれる視覚語の（日本語, 英語代表）対。コンポーザーの**接地プレビュー**
    /// （「海 → sea」のような色付きチップ）に使う。抽出規則は `includeTerms` と同一。
    public static func groundedPairs(in criteria: String) -> [(japanese: String, english: String)] {
        let lower = criteria.lowercased()
        var out: [(japanese: String, english: String)] = []
        for entry in visualWords {
            guard let jp = entry.jp.first(where: { criteria.contains($0) || lower.contains($0) }),
                  let en = entry.en.first else { continue }
            out.append((japanese: jp, english: en))
        }
        return out
    }

    /// 英語タグ（Vision 識別子等）→ 日本語代表語。頻出タグをサジェストチップとして
    /// **日本語表示**するための逆引き（対応が無いタグは nil＝チップに出さない）。
    public static func japaneseLabel(forTag tag: String) -> String? {
        let t = tag.lowercased()
        for entry in visualWords where entry.en.contains(where: { $0 == t || t.contains($0) || $0.contains(t) }) {
            return entry.jp.first
        }
        return nil
    }

    /// 「人が写っていない」系の否定表現を含むか。
    static func hasPeopleNegation(_ criteria: String) -> Bool {
        let lower = criteria.lowercased()
        return peopleNegations.contains { criteria.contains($0) || lower.contains($0) }
    }
}
