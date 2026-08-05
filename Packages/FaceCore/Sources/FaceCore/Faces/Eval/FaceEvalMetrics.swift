import Foundation

/// 顔認識の精度指標（純ロジック・テスト対象）。精度計測ハーネス（FaceAccuracyEvalTests）が
/// 「正解ラベル付きデータセット」に対して本番同一パイプラインの出力を採点するために使う。
///
/// - クラスタリング品質: **B-Cubed 精度/再現率/F1**（クラスタリング評価の標準指標）と
///   **ペア一致 P/R/F1**。精度（precision）＝混入の少なさ、再現率（recall）＝分裂の少なさ、
///   と対応するので「しきい値・ゲート変更がどちらをどれだけ動かしたか」が分離して見える。
/// - 検証（verification）: 同一人物ペア/別人ペアのコサイン類似度から **TAR@FAR** と
///   最良 F1 しきい値を出す（しきい値議論の実データ根拠になる）。
public enum FaceEvalMetrics {

    // MARK: - クラスタリング品質

    public struct ClusteringScore: Sendable, Equatable {
        public let bcubedPrecision: Double
        public let bcubedRecall: Double
        public let bcubedF1: Double
        public let pairPrecision: Double
        public let pairRecall: Double
        public let pairF1: Double
        public let clusterCount: Int
        /// 正解人物の数（分裂率の分母）。
        public let identityCount: Int
        /// **分裂率**＝1 人あたり何個のクラスタに割れたか（人物ごとの「その人の顔が入っている
        /// 相異なるクラスタ数」の平均）。1.0 が理想。
        ///
        /// ⚠️ B-Cubed 再現率も分裂に反応するが、`0.435` のような値は「ピープル画面に人物が
        /// 何人並ぶか」を教えてくれない。実ライブラリの破綻（3 人 → 2000 人）は**この指標**で
        /// しか見えないため一級指標として持つ（ADR-67・少数 ID×大量写真の計測穴）。
        public let clustersPerIdentity: Double
        /// 最も分裂した人物のクラスタ数（最悪値。平均だけだと外れ値が埋もれる）。
        public let maxClustersForOneIdentity: Int
    }

    /// - Parameters:
    ///   - assignments: 項目 → 予測クラスタ ID（未割当は **項目ごとに一意な負 ID** を渡すこと。
    ///     同一の -1 を共有させると「未割当同士が同一クラスタ」扱いになり precision が壊れる）。
    ///   - truth: 項目 → 正解人物ラベル。
    public static func clusteringScore(assignments: [String: Int],
                                       truth: [String: String]) -> ClusteringScore? {
        let items = Array(assignments.keys).filter { truth[$0] != nil }
        guard !items.isEmpty else { return nil }
        var clusterMembers: [Int: [String]] = [:]
        var classMembers: [String: [String]] = [:]
        for item in items {
            clusterMembers[assignments[item]!, default: []].append(item)
            classMembers[truth[item]!, default: []].append(item)
        }

        // B-Cubed: 各項目について「同クラスタ∩同クラス」の割合を平均。
        var precisionSum = 0.0
        var recallSum = 0.0
        for item in items {
            let cluster = clusterMembers[assignments[item]!]!
            let cls = classMembers[truth[item]!]!
            let overlap = Double(cluster.filter { truth[$0] == truth[item] }.count)
            precisionSum += overlap / Double(cluster.count)
            recallSum += overlap / Double(cls.count)
        }
        let n = Double(items.count)
        let bp = precisionSum / n
        let br = recallSum / n
        let bf = (bp + br) > 0 ? 2 * bp * br / (bp + br) : 0

        // ペア一致: 全ペアで「同クラスタ予測」と「同一人物正解」を突き合わせる。
        var truePositive = 0.0, falsePositive = 0.0, falseNegative = 0.0
        for i in items.indices {
            for j in (i + 1)..<items.count {
                let sameCluster = assignments[items[i]] == assignments[items[j]]
                let samePerson = truth[items[i]] == truth[items[j]]
                if sameCluster && samePerson { truePositive += 1 }
                else if sameCluster && !samePerson { falsePositive += 1 }
                else if !sameCluster && samePerson { falseNegative += 1 }
            }
        }
        let pp = truePositive + falsePositive > 0 ? truePositive / (truePositive + falsePositive) : 1
        let pr = truePositive + falseNegative > 0 ? truePositive / (truePositive + falseNegative) : 1
        let pf = (pp + pr) > 0 ? 2 * pp * pr / (pp + pr) : 0
        // 分裂率: 人物ごとに「その人の顔が入っている相異なるクラスタ数」を数えて平均する。
        var clustersOf: [String: Set<Int>] = [:]
        for item in items { clustersOf[truth[item]!, default: []].insert(assignments[item]!) }
        let perIdentity = clustersOf.values.map(\.count)
        let fragmentation = perIdentity.isEmpty ? 0
            : Double(perIdentity.reduce(0, +)) / Double(perIdentity.count)

        return ClusteringScore(bcubedPrecision: bp, bcubedRecall: br, bcubedF1: bf,
                               pairPrecision: pp, pairRecall: pr, pairF1: pf,
                               clusterCount: Set(assignments.values).count,
                               identityCount: classMembers.count,
                               clustersPerIdentity: fragmentation,
                               maxClustersForOneIdentity: perIdentity.max() ?? 0)
    }

    // MARK: - 検証（同一人物/別人ペアの類似度）

    public struct VerificationScore: Sendable {
        public let samePairs: Int
        public let differentPairs: Int
        public let sameMean: Double
        public let differentMean: Double
        /// FAR（別人を誤って同一と判定する率）を固定したときの TAR（同一人物を正しく通す率）。
        public let tarAtFar01: Double     // FAR = 1%
        public let tarAtFar001: Double    // FAR = 0.1%
        /// F1 が最良になるしきい値（クラスタリングしきい値の実データ根拠）。
        public let bestF1Threshold: Float
        public let bestF1: Double
    }

    /// - Parameters:
    ///   - sameSims: 同一人物ペアのコサイン類似度。
    ///   - differentSims: 別人ペアのコサイン類似度。
    public static func verificationScore(sameSims: [Float],
                                         differentSims: [Float]) -> VerificationScore? {
        guard !sameSims.isEmpty, !differentSims.isEmpty else { return nil }
        let sortedDifferent = differentSims.sorted(by: >)   // 高い＝危険（誤受理）側から

        func tar(atFar far: Double) -> Double {
            // 別人ペアの上位 far 割合が誤受理になるしきい値 → それ以上の同一ペア率。
            let index = max(0, min(sortedDifferent.count - 1, Int(Double(sortedDifferent.count) * far)))
            let threshold = sortedDifferent[index]
            return Double(sameSims.filter { $0 >= threshold }.count) / Double(sameSims.count)
        }

        // 最良 F1 しきい値: 0.20〜0.80 を 0.01 刻みでスイープ。
        var bestThreshold: Float = 0
        var bestF1 = -1.0
        var threshold: Float = 0.20
        while threshold <= 0.80 {
            let tp = Double(sameSims.filter { $0 >= threshold }.count)
            let fp = Double(differentSims.filter { $0 >= threshold }.count)
            let fn = Double(sameSims.count) - tp
            let p = tp + fp > 0 ? tp / (tp + fp) : 1
            let r = tp / Double(sameSims.count)
            let f1 = (p + r) > 0 ? 2 * p * r / (p + r) : 0
            if f1 > bestF1 { bestF1 = f1; bestThreshold = threshold }
            threshold += 0.01
            _ = fn
        }

        let sameMean = sameSims.reduce(0.0) { $0 + Double($1) } / Double(sameSims.count)
        let differentMean = differentSims.reduce(0.0) { $0 + Double($1) } / Double(differentSims.count)
        return VerificationScore(samePairs: sameSims.count, differentPairs: differentSims.count,
                                 sameMean: sameMean, differentMean: differentMean,
                                 tarAtFar01: tar(atFar: 0.01), tarAtFar001: tar(atFar: 0.001),
                                 bestF1Threshold: bestThreshold, bestF1: bestF1)
    }
}
