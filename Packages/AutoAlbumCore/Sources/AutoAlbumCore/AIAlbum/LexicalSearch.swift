import Foundation

/// 字句検索（完全一致寄り）。OCR 文字・地名・国・人物に対し、語の部分一致でスコアリングする純ロジック。
/// CLIP の意味検索が苦手な「看板/書類/固有名詞」を拾う。マッチ数の多い順に返す。
public enum LexicalSearch {
    public static func rank(_ photos: [EnrichedPhoto], keywords: [String]) -> [EnrichedPhoto] {
        let terms = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var scored: [(photo: EnrichedPhoto, score: Int)] = []
        for photo in photos {
            let fields = ([photo.placeName, photo.country].compactMap { $0 }
                          + photo.people)
                .map { $0.lowercased() }
            guard !fields.isEmpty else { continue }
            var score = 0
            for term in terms {
                for field in fields where field.contains(term) { score += 1 }   // 言及が多いほど高スコア
            }
            if score > 0 { scored.append((photo, score)) }
        }
        return scored.sorted { $0.score > $1.score }.map(\.photo)
    }
}

/// 複数のランク付き結果を Reciprocal Rank Fusion で統合する純ロジック。
/// 両方の検索（字句＋意味）に現れる写真が上位に来る。空のリストは無視する。
public enum HybridFusion {
    public static func fuse(_ lists: [[EnrichedPhoto]], k: Int = 60) -> [EnrichedPhoto] {
        var score: [String: Double] = [:]
        var byID: [String: EnrichedPhoto] = [:]
        for list in lists {
            for (rank, photo) in list.enumerated() {
                score[photo.id, default: 0] += 1.0 / Double(k + rank + 1)
                if byID[photo.id] == nil { byID[photo.id] = photo }
            }
        }
        return score.sorted { $0.value > $1.value }.compactMap { byID[$0.key] }
    }
}
