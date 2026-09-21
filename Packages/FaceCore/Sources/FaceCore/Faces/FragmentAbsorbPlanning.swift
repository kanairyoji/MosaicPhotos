import Foundation

// MARK: - 断片の自動吸収: 判定（純ロジック・ADR-154/155/162）

/// **1 つの断片をどうするか**を決める（SwiftData に触らない・テスト対象）。
///
/// ⚠️ ここに出したのは**判定だけ**で、収集（DB 読み）・適用（併合と保存）・記録は
/// 呼び出し側（`FaceStore.absorbFragments`）に残してある。以前は 4 つが 1 つの関数に
/// 混ざっていて、**分岐 46**——このリポジトリ全体で最大だった（複雑度スコアボード）。
/// 判定は純粋なので、出せば SwiftData 無しで組み合わせを試せる。
///
/// ⚠️ **判定の順番は変えないこと**（記録の内訳が意味を保つ）。
/// バー → マージン → 汚れ、の順に落とす。内訳（`bar=` `margin=` `blocked=`）は
/// 「次にどの条件を緩めるか」を実測で決めるための材料そのもの（ADR-155/162）。
enum FragmentAbsorbPlanning {

    /// 近さを比べる相手（確立した人物＝`isTarget` と、それ以外の「3 枚以上の人物」）。
    struct Neighbour: Equatable {
        let clusterID: Int
        let centroid: [Float]
        /// 吸収先になり得るか（名前かアンカーがあり、一定枚数以上）。
        let isTarget: Bool
        /// その人物の写真（同一写真に一緒に写っていたら吸収しない）。
        let refKeys: Set<String>

        init(clusterID: Int, centroid: [Float], isTarget: Bool, refKeys: Set<String>) {
            self.clusterID = clusterID
            self.centroid = centroid
            self.isTarget = isTarget
            self.refKeys = refKeys
        }
    }

    /// 見送りの理由（内訳を数えるため）。
    enum SkipReason: Equatable {
        /// 近さがバーに届かない（＝吸収先が無い場合も含む）。
        case belowBar
        /// 2 位が近すぎて紛らわしい（人に尋ねる）。
        case marginal
        /// 同一写真・負例・「別人」記録がある。
        case blocked
    }

    enum Outcome: Equatable {
        case absorb(into: Int)
        case skip(SkipReason)
    }

    struct Decision: Equatable {
        let outcome: Outcome
        /// **バー以外の条件を全部通った**ときの近さ（通らなければ nil）。
        /// 「バーを 0.65 にしたら何件寄るか」を数えるための材料（ADR-162）。
        let cleanSimilarity: Float?
    }

    /// - Parameters:
    ///   - bar: 自動吸収のバー（`tuning.autoAbsorbBar`）。
    ///   - margin: 1 位と 2 位の最小差（`FaceStore.absorbMargin`）。
    ///   - isBlockedPair: 「別人」記録のある対か。
    static func decide(fragmentID: Int,
                       centroid: [Float],
                       refKeys: Set<String>,
                       neighbours: [Neighbour],
                       negatives: [FaceClustering.NegativePair],
                       bar: Float,
                       margin: Float,
                       negativeSameThreshold: Float,
                       isBlockedPair: (Int, Int) -> Bool) -> Decision {
        // 最も近い「吸収先」と、最も近い「その他の人物」（2 位）を出す。
        var best: (id: Int, sim: Float, refKeys: Set<String>, centroid: [Float])?
        var runnerUp: Float = -1
        for neighbour in neighbours where neighbour.clusterID != fragmentID {
            let sim = FaceClustering.dot(centroid, neighbour.centroid)
            if neighbour.isTarget, sim > (best?.sim ?? -1) {
                if let previous = best { runnerUp = max(runnerUp, previous.sim) }
                best = (neighbour.clusterID, sim, neighbour.refKeys, neighbour.centroid)
            } else {
                runnerUp = max(runnerUp, sim)
            }
        }
        guard let best else { return Decision(outcome: .skip(.belowBar), cleanSimilarity: nil) }

        // ⚠️ **バー以外の条件は、バーで落ちた断片についても評価する**——
        // 「バーを下げたら何件寄るか」を数えるため（ADR-162）。
        let marginOK = best.sim - runnerUp >= margin
        let clean = marginOK
            && refKeys.isDisjoint(with: best.refKeys)
            && !isBlockedPair(fragmentID, best.id)
            && !FaceClustering.negativeRejects(centroid, centroid: best.centroid,
                                               negatives: negatives,
                                               sameThreshold: negativeSameThreshold)
        let cleanSimilarity = clean ? best.sim : nil

        guard best.sim >= bar else {
            return Decision(outcome: .skip(.belowBar), cleanSimilarity: cleanSimilarity)
        }
        guard marginOK else {
            return Decision(outcome: .skip(.marginal), cleanSimilarity: cleanSimilarity)
        }
        guard clean else {
            return Decision(outcome: .skip(.blocked), cleanSimilarity: cleanSimilarity)
        }
        return Decision(outcome: .absorb(into: best.id), cleanSimilarity: cleanSimilarity)
    }

    // MARK: - 選別（誰が断片で、誰が吸収先か・ADR-154/155）

    /// クラスタ 1 つぶんの、選別に要る情報だけ。
    struct Shape: Equatable {
        let photos: Int
        let hasName: Bool
        let isGrouped: Bool      // 束ね（`personGroupID`）に入っている
        let hasAnchor: Bool      // 確認済みの顔がある

        init(photos: Int, hasName: Bool, isGrouped: Bool, hasAnchor: Bool) {
            self.photos = photos
            self.hasName = hasName
            self.isGrouped = isGrouped
            self.hasAnchor = hasAnchor
        }

        /// 利用者が「この人だ」と表明した跡があるか（名前・確認済みの顔）。
        var isUserStated: Bool { hasName || hasAnchor }
    }

    /// **断片**＝寄せてよい小さな塊。無名・アンカーなし・束ねなしで、`maxPhotos` 枚以下。
    ///
    /// ⚠️ 枚数の上限は 1〜2 枚（ADR-154）。増やすほど「間違えたときに動かす写真」が増え、
    /// 人物どうしの結合（自動化しないと決めた・ADR-153）に近づく。
    static func isFragment(_ shape: Shape, maxPhotos: Int) -> Bool {
        shape.photos >= 1 && shape.photos <= maxPhotos
            && !shape.isUserStated && !shape.isGrouped
    }

    /// **吸収先**＝確立した人物。利用者が表明していて、`minPhotos` 枚以上。
    static func isTarget(_ shape: Shape, minPhotos: Int) -> Bool {
        shape.photos >= minPhotos && shape.isUserStated
    }

    /// **上限だけが理由**で対象外になった塊（上限を上げれば寄せられた分）。
    /// 「断片は何枚まで自動で寄せてよいか」を実測で決めるための材料（ADR-155）。
    static func isTooBigToAbsorb(_ shape: Shape, maxPhotos: Int, minPhotos: Int) -> Bool {
        shape.photos > maxPhotos && shape.photos < minPhotos
            && !shape.isUserStated && !shape.isGrouped
    }

    /// 見送りの内訳（呼び出し側が数えるための入れ物）。
    struct SkipCounts: Equatable {
        var belowBar = 0
        var marginal = 0
        var blocked = 0

        var total: Int { belowBar + marginal + blocked }

        mutating func record(_ reason: SkipReason) {
            switch reason {
            case .belowBar: belowBar += 1
            case .marginal: marginal += 1
            case .blocked:  blocked += 1
            }
        }
    }
}
