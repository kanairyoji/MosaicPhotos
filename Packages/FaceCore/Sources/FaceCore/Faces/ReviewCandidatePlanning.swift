import Foundation

// MARK: - レビューカードの候補選び（純ロジック・ADR-46/123/152）

/// **「どの対を尋ねるか」**を決める（SwiftData に触らない・テスト対象）。
///
/// ⚠️ 出したのは**選び方だけ**。顔の読み出し・カードの組み立ては
/// `FaceStore.reviewItems` に残してある——以前はそこに 5 つの段
/// （母数づくり・「別人」記録の索引・候補選び・顔の読み出し・組み立て）が
/// 1 つの関数に並んでいて、**分岐 45 / 159 行**だった（複雑度スコアボードで最大）。
enum ReviewCandidatePlanning {

    /// A1 統合サジェストの候補対。`sim` の降順で返す。
    struct Pair: Equatable {
        let a: Int
        let b: Int
        let sim: Float
    }

    /// 統合サジェストの候補を選ぶ。
    ///
    /// 規則（順番に意味がある・どれも実フィードバックが出典）:
    /// 1. **片側は必ず基準**（`focus`）。基準を絞ると探索は「人物数²」から
    ///    「基準数 × 人物数」に落ちる（ADR-123）。
    /// 2. 重心の近さが**統合の一歩手前の帯**（`bandFloor` 以上）にあること。
    /// 3. 「別人」と答えた対・同一写真で統合できない対は出さない（ADR-152）。
    /// 4. **別々の名前が付いた人物どうしは出さない**——利用者が既に別人と表明している。
    /// 5. 近い順に `scanLimit` 件だけ残す（このあとの顔の読み出しを有界にするため）。
    ///
    /// ⚠️ 5 の打ち切りは**並べ替えた後**に行う。先に打ち切ると「たまたま先に見つかった対」が
    /// 残り、いちばん尋ねる価値のある対（近い対）が落ちる。
    static func mergeCandidates(focus: [Int],
                                others: [Int],
                                centroid: [Int: [Float]],
                                name: [Int: String],
                                bandFloor: Float,
                                scanLimit: Int,
                                isMarkedNotSame: (Int, Int) -> Bool,
                                namesConflict: (String?, String?) -> Bool) -> [Pair] {
        var pairs: [Pair] = []
        for a in focus {
            guard let ca = centroid[a] else { continue }
            for b in others where b != a {
                guard let cb = centroid[b] else { continue }
                let sim = FaceClustering.dot(ca, cb)
                guard sim >= bandFloor, !isMarkedNotSame(a, b) else { continue }
                guard !namesConflict(name[a], name[b]) else { continue }
                pairs.append(Pair(a: a, b: b, sim: sim))
            }
        }
        pairs.sort { $0.sim > $1.sim }
        return Array(pairs.prefix(scanLimit))
    }
}
