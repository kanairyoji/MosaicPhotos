import Foundation

/// クラスタの**事後監査**（ADR-69）: 「この人物、実は 2 人が混ざっていないか？」を調べる純ロジック。
///
/// ## なぜ必要か
/// 統合はユーザー確認を経るが、**確認した時点では材料が足りない**ことがある。兄弟のように似た顔は
/// 数枚だけ見ても区別できず、同じ人としてまとめてしまう。写真が増えると分布が見えてきて、
/// 「実は 2 つの山だった」と分かる——その気づきを機械側からも拾う。
///
/// ## ADR-59（外れ値除去・不採用）との違い
/// ADR-59 は「重心から遠い顔＝混入」とみなして 1 顔ずつ抜く方式で、成長データでは
/// 「遠い顔＝同一人物の別年齢」を誤って弾き、総合 F1 が下がった。
/// 本監査は個々の顔ではなく**クラスタ全体の形**を見る:
/// - 成長による広がりは**連続した 1 つの帯**（年齢順に少しずつ変わる）
/// - 別人の混入は**離れた 2 つの塊**（間が空く）
/// この違いを 2 分割の分離度で測る。さらに**同じ写真に両群の顔が居る**なら、
/// 同一人物は 1 枚に 1 回しか写れないので**別人である決定的な証拠**になる。
public enum FaceClusterAudit {

    /// 分割の提案（＝「この人物は 2 人では？」）。
    public struct SplitSuggestion: Sendable, Equatable {
        /// 群 A / 群 B のメンバー添字（入力配列に対する）。
        public let groupA: [Int]
        public let groupB: [Int]
        /// 各群の凝集度（群内の平均コサイン類似度）。
        public let cohesionA: Float
        public let cohesionB: Float
        /// 群間の平均コサイン類似度。
        public let separation: Float
        /// 分離マージン ＝ min(cohesionA, cohesionB) − separation。大きいほど「2 つの塊」。
        public let margin: Float
        /// **同じ写真に両群の顔が居た枚数**。1 枚でもあれば別人の決定的証拠（同一人物は 1 枚に 1 回）。
        public let coOccurringPhotos: Int

        /// 決定的証拠つきか（＝ユーザーに尋ねるまでもなく別人の可能性が高い）。
        public var hasHardEvidence: Bool { coOccurringPhotos > 0 }
    }

    /// 監査のしきい値（計測で決める・ADR-69）。
    public struct Config: Sendable {
        /// 監査対象にする最小メンバー数（少なすぎると 2 分割は意味を持たない）。
        public var minMembers: Int
        /// 各群に最低これだけ必要（片側 1〜2 枚の「外れ値」を分割と呼ばない）。
        public var minGroupSize: Int
        /// 分離マージンの下限。これ未満なら「1 つの連続した帯」とみなす。
        public var minMargin: Float
        /// 群間類似度の上限。これ以上似ていれば同一人物の別時期とみなす。
        public var maxSeparation: Float

        public init(minMembers: Int = 8, minGroupSize: Int = 3,
                    minMargin: Float = 0.15, maxSeparation: Float = 0.45) {
            self.minMembers = minMembers
            self.minGroupSize = minGroupSize
            self.minMargin = minMargin
            self.maxSeparation = maxSeparation
        }

        /// 「この人物を整理」用の緩和プロファイル（ADR-111 追記・実フィードバック）。
        ///
        /// レビューカード（受動提示）用の校正値（facenet: margin 0.25 / separation 0.35）は
        /// **クラスタリングが混ぜたものを構造的に分割できない**: 2 人が 1 クラスタに入るのは
        /// 類似度がしきい値（0.40〜0.55）以上だからで、その群間類似は常に 0.35 を超える。
        /// 整理画面はユーザーが「混ざっている」と自ら開いた文脈＝候補を出さないことこそが失敗
        /// なので、群間上限をしきい値の上（0.65）まで緩め、マージン下限をほぼ外して
        /// 「候補を見せて人間が判断する」に寄せる（誤提案の防波堤は UI 側の最大グループ保護と
        /// ユーザーのチェック操作）。
        public static let cleanup = Config(minMembers: 6, minGroupSize: 2,
                                           minMargin: 0.03, maxSeparation: 0.65)
    }

    /// クラスタを 2 分割して「別人が混ざっている」かを判定する。
    /// - Parameters:
    ///   - embeddings: メンバーの埋め込み（正規化は内部で行う）。
    ///   - photoKeys: 各メンバーが写っている写真キー（`embeddings` と同じ並び）。
    ///     同じ写真に両群の顔が居れば決定的証拠になる。空なら証拠なしとして扱う。
    /// - Returns: 疑わしければ提案、問題なければ nil。
    public static func auditForSplit(embeddings: [[Float]], photoKeys: [String] = [],
                                     config: Config = Config()) -> SplitSuggestion? {
        guard embeddings.count >= config.minMembers else { return nil }
        let vectors = embeddings.map { FaceClustering.normalized($0) }
        guard let split = twoMeans(vectors) else { return nil }
        guard split.a.count >= config.minGroupSize, split.b.count >= config.minGroupSize else {
            return nil
        }

        let cohesionA = meanPairwise(split.a.map { vectors[$0] })
        let cohesionB = meanPairwise(split.b.map { vectors[$0] })
        let separation = meanCross(split.a.map { vectors[$0] }, split.b.map { vectors[$0] })
        let margin = min(cohesionA, cohesionB) - separation

        // 同じ写真に両群の顔が居るか（別人の決定的証拠）。
        var coOccurring = 0
        if photoKeys.count == embeddings.count {
            let photosA = Set(split.a.map { photoKeys[$0] })
            let photosB = Set(split.b.map { photoKeys[$0] })
            coOccurring = photosA.intersection(photosB).count
        }

        // 決定的証拠があるなら分離度が甘くても提案する（同一人物は 1 枚に 1 回しか写れない）。
        let separated = margin >= config.minMargin && separation <= config.maxSeparation
        guard separated || coOccurring > 0 else { return nil }

        return SplitSuggestion(groupA: split.a, groupB: split.b,
                               cohesionA: cohesionA, cohesionB: cohesionB,
                               separation: separation, margin: margin,
                               coOccurringPhotos: coOccurring)
    }

    // MARK: - 2-means（コサイン・決定的）

    /// 決定的な 2-means。初期中心は**最も離れた 2 点**（最遠点対の近似）にする。
    /// 乱数を使わないので、同じ入力なら常に同じ結果＝夜間ジョブでも結果が揺れない。
    static func twoMeans(_ vectors: [[Float]], iterations: Int = 12) -> (a: [Int], b: [Int])? {
        guard vectors.count >= 2 else { return nil }
        // 最遠点対の近似: 任意の点から最も遠い点 p、p から最も遠い点 q。
        func farthest(from i: Int) -> Int {
            var best = i, bestSim = Float.greatestFiniteMagnitude
            for j in vectors.indices where j != i {
                let s = FaceClustering.dot(vectors[i], vectors[j])
                if s < bestSim { bestSim = s; best = j }
            }
            return best
        }
        let p = farthest(from: 0)
        let q = farthest(from: p)
        guard p != q else { return nil }

        var centerA = vectors[p], centerB = vectors[q]
        var groupA: [Int] = [], groupB: [Int] = []
        for _ in 0..<iterations {
            groupA = []; groupB = []
            for i in vectors.indices {
                if FaceClustering.dot(vectors[i], centerA) >= FaceClustering.dot(vectors[i], centerB) {
                    groupA.append(i)
                } else {
                    groupB.append(i)
                }
            }
            guard !groupA.isEmpty, !groupB.isEmpty else { return nil }
            let newA = centroid(groupA.map { vectors[$0] })
            let newB = centroid(groupB.map { vectors[$0] })
            // 収束したら打ち切り。
            if FaceClustering.dot(newA, centerA) > 0.9999,
               FaceClustering.dot(newB, centerB) > 0.9999 { break }
            centerA = newA; centerB = newB
        }
        return (groupA, groupB)
    }

    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            for i in sum.indices { sum[i] += v[i] }
        }
        return FaceClustering.normalized(sum)
    }

    /// 群内の全ペア平均類似度（凝集度）。1 要素なら 1.0 とみなす。
    static func meanPairwise(_ vectors: [[Float]]) -> Float {
        guard vectors.count >= 2 else { return 1 }
        var sum: Float = 0, n = 0
        for i in vectors.indices {
            for j in (i + 1)..<vectors.count {
                sum += FaceClustering.dot(vectors[i], vectors[j]); n += 1
            }
        }
        return n > 0 ? sum / Float(n) : 1
    }

    /// 群間の全ペア平均類似度（分離度）。
    static func meanCross(_ a: [[Float]], _ b: [[Float]]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 1 }
        var sum: Float = 0
        for x in a { for y in b { sum += FaceClustering.dot(x, y) } }
        return sum / Float(a.count * b.count)
    }
}
