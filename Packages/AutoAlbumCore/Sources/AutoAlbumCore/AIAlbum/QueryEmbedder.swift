import Foundation

/// クエリ埋め込み（肯定フレーズの選定＋除外語ベクトルの生成）の**唯一の実装**。
/// フル評価（`AIAlbumSearcher.searchWithPool`）と増分評価（`AIAlbumService.refreshIncremental`）は
/// 同じスコアプールを共有するため、**必ず同じ規則**で埋め込み・採点しなければならない。
/// 旧実装は両者に同じ規則がコピペされ、同期がコメント頼みだった＝ここに集約して型で担保する。
struct QueryEmbedder: Sendable {
    let textEmbedder: TextEmbedder?

    /// クエリ埋め込みの結果（肯定ベクトル群＋除外語ベクトル群）。
    /// 肯定は**マルチプローブ**（主フレーズ＋FM の言い換えプローブ・ADR-35）。
    struct QueryVectors: Sendable {
        let positives: [[Float]]
        let negatives: [[Float]]
        var positive: [Float] { positives[0] }   // 主フレーズ（従来互換）
    }

    /// 肯定側の意味スコア＝**プローブ群との最大コサイン**（どれか 1 つの言い回しに近ければ拾う＝
    /// 言い換えの取りこぼし回収）。除外概念のほうが近ければ nil（相対判定のみ・絶対閾値なし＝ADR-24）。
    /// フル評価（searchWithPool）と増分評価（refreshIncremental）は必ずこの同一規則で採点する。
    static func semanticScore(_ q: QueryVectors, photoVector v: [Float]) -> Float? {
        let pos = q.positives.map { ClipMath.cosine($0, v) }.max() ?? -1
        if !q.negatives.isEmpty {
            let neg = q.negatives.map { ClipMath.cosine($0, v) }.max() ?? -1
            if neg >= pos { return nil }
        }
        return pos
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

    /// 肯定フレーズ（＋言い換えプローブ）＋除外語群を埋め込む。埋め込み不可（モデル未同梱・
    /// 主フレーズの embed 失敗）なら nil＝意味採点なし（プローブ/除外語の失敗は個別にスキップ）。
    /// プローブは主フレーズと重複しないものだけ・最大 4 本（FM 生成分のサニタイズは解釈側）。
    /// ⚠️ **除外語があるアルバムではプローブを使わない**。除外の対比は「neg ≥ max(肯定)」の相対判定で、
    /// プローブが肯定の最大値を底上げすると除外が効かなくなる（実障害:「人のいない風景」に人物写真が
    /// 混入＝ADR-35 の回帰）。除外つきは主フレーズのみ＝ADR-35 以前の対比挙動を維持する。
    func embed(phrase: String, probes: [String] = [], excludeTerms: [String]) async -> QueryVectors? {
        guard let textEmbedder, textEmbedder.isAvailable,
              let main = await textEmbedder.embed(phrase) else { return nil }
        var positives: [[Float]] = [main]
        let lowerPhrase = phrase.lowercased()
        let effectiveProbes = excludeTerms.isEmpty ? probes : []
        for probe in effectiveProbes.prefix(4) {
            let p = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, p.lowercased() != lowerPhrase else { continue }
            if let v = await textEmbedder.embed(p) { positives.append(v) }
        }
        var negatives: [[Float]] = []
        for term in excludeTerms {
            if let neg = await textEmbedder.embed(Self.excludePrompt(term)) { negatives.append(neg) }
        }
        return QueryVectors(positives: positives, negatives: negatives)
    }
}
