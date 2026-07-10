import Foundation

/// クエリ埋め込み（肯定フレーズの選定＋除外語ベクトルの生成）の**唯一の実装**。
/// フル評価（`AIAlbumSearcher.searchWithPool`）と増分評価（`AIAlbumService.refreshIncremental`）は
/// 同じスコアプールを共有するため、**必ず同じ規則**で埋め込み・採点しなければならない。
/// 旧実装は両者に同じ規則がコピペされ、同期がコメント頼みだった＝ここに集約して型で担保する。
struct QueryEmbedder: Sendable {
    let textEmbedder: TextEmbedder?

    /// クエリ埋め込みの結果（肯定ベクトル＋除外語ベクトル群）。
    struct QueryVectors: Sendable {
        let positive: [Float]
        let negatives: [[Float]]
    }

    /// 除外語 → CLIP プロンプト（ゼロショットの定番形）。
    static func excludePrompt(_ term: String) -> String { "a photo of \(term)" }

    /// 除外があるときの**肯定側フレーズ**。include 語があればそれ、無ければ英訳文から
    /// 否定節を落とした先頭部を使う（"A landscape photo without any people." → "A landscape photo"）。
    /// 否定入りの全文を CLIP に渡すと "people" が逆に人物写真を引き上げるため（CLIP は否定を
    /// 理解しない）、肯定側には否定語を残さないことを保証する。
    static func positivePhrase(include: [String], semanticText: String) -> String {
        if !include.isEmpty { return include.joined(separator: ", ") }
        let text = semanticText.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in [" without ", " with no ", " except ", " excluding ", " but no "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let head = String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty { return head }
            }
        }
        return text
    }

    /// CLIP に渡す肯定側フレーズの選定規則（フル/増分共通）：
    /// - 除外あり: include 語だけ（無ければ否定節を落とした英訳文）＝肯定側に否定語を残さない
    /// - 除外なし: 英訳文（空なら include 語の結合）
    static func phrase(include: [String], exclude: [String], semanticText: String) -> String {
        let trimmed = semanticText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !exclude.isEmpty {
            return positivePhrase(include: include, semanticText: trimmed)
        }
        return trimmed.isEmpty ? include.joined(separator: ", ") : trimmed
    }

    /// 肯定フレーズ＋除外語群を埋め込む。埋め込み不可（モデル未同梱・肯定の embed 失敗）なら
    /// nil＝意味採点なし（除外語の embed 失敗は個別にスキップ＝従来どおり）。
    func embed(phrase: String, excludeTerms: [String]) async -> QueryVectors? {
        guard let textEmbedder, textEmbedder.isAvailable,
              let positive = await textEmbedder.embed(phrase) else { return nil }
        var negatives: [[Float]] = []
        for term in excludeTerms {
            if let neg = await textEmbedder.embed(Self.excludePrompt(term)) { negatives.append(neg) }
        }
        return QueryVectors(positive: positive, negatives: negatives)
    }
}
