import Foundation

/// **本番のクラスタリング設定を 1 か所にまとめたもの**（純ロジック・テスト対象・ADR-198）。
///
/// ## なぜ出したか
/// 10 個のノブ（`baseThreshold` / `assignMargin` / `sizeAdaptiveMarginMax` /
/// `negativeSameThreshold` / `rivalAwareMarginGate` / `rivalAwareSizeMargin` /
/// `rivalAwareSizeMarginMaxPeople` / `rivalAlikeMargin` / `effectiveThresholdCap` /
/// `effectiveThresholdCapMaxPeople`）が、**スキャン時（`FaceStore.makeClustering`）と
/// 再クラスタ（`FaceStore+Rebuild`）の 2 か所に条件つきの代入文としてコピー**されていた。
/// 片方にノブを足し忘れれば、同じライブラリでも「スキャンで入った顔」と「再クラスタで
/// 入った顔」が別の規則で判定される——誰も気づけない種類のズレになる。
///
/// ノブの意味と出典（**数値は `face-accuracy.md` の実測で校正済み。勝手に動かさない**）:
/// - `baseThreshold`: 確立した人物は校正の引き上げ分を免除する（ADR-141）
/// - `assignMargin`: マージンゲート＝1 位と 2 位の差が小さい紛らわしい顔は入れない（ADR-57）
/// - `sizeAdaptiveMarginMax`: 小さい/新しいクラスタほど合流を厳しく（ADR-58）
/// - `rivalAwareMarginGate`: マージンゲートの免除。**校正で bar が上がっているときだけ**（ADR-126）
/// - `rivalAwareSizeMargin` / `...MaxPeople`: サイズ適応の免除・少人数ライブラリ限定（ADR-68）
/// - `effectiveThresholdCap` / `...MaxPeople`: 実効しきい値の頭打ち。校正で上がったしきい値へ
///   さらにサイズ加算が乗って跳ね上がるのを止める（ADR-68 追補）
public enum FaceClusteringSetup {

    /// 少人数ライブラリ向けの免除フラグ。本番値は `.production`。
    public struct Flags: Sendable, Equatable {
        public var rivalAwareMarginGateWhenCalibratedUp: Bool
        public var rivalAwareSizeMargin: Bool
        public var rivalAwareSizeMarginMaxPeople: Int
        public var capEffectiveThresholdWhenFewPeople: Bool
        public var effectiveThresholdCapMaxPeople: Int

        public init(rivalAwareMarginGateWhenCalibratedUp: Bool = false,
                    rivalAwareSizeMargin: Bool = true,
                    rivalAwareSizeMarginMaxPeople: Int = 10,
                    capEffectiveThresholdWhenFewPeople: Bool = true,
                    effectiveThresholdCapMaxPeople: Int = 10) {
            self.rivalAwareMarginGateWhenCalibratedUp = rivalAwareMarginGateWhenCalibratedUp
            self.rivalAwareSizeMargin = rivalAwareSizeMargin
            self.rivalAwareSizeMarginMaxPeople = rivalAwareSizeMarginMaxPeople
            self.capEffectiveThresholdWhenFewPeople = capEffectiveThresholdWhenFewPeople
            self.effectiveThresholdCapMaxPeople = effectiveThresholdCapMaxPeople
        }

        /// 本番値（`FaceStore` の静的定数と同じ）。
        public static let production = Flags()
    }

    /// 設定済みの `FaceClustering` を作る。**スキャン時も再クラスタもここを通す。**
    ///
    /// - Parameters:
    ///   - threshold: 校正後のしきい値（`calibratedThreshold()`）。
    ///   - anchoredClusterIDs: アンカー（ユーザーが確認した顔）を持つクラスタ。
    ///     校正の引き上げ分を免除する対象（ADR-141）。
    public static func make(threshold: Float,
                            qualityFloor: Float,
                            tuning: FaceTuning,
                            seeds: [FaceClustering.Cluster],
                            minimumNextID: Int,
                            anchoredClusterIDs: Set<Int>,
                            flags: Flags = .production) -> FaceClustering {
        var clustering = FaceClustering(threshold: threshold, qualityFloor: qualityFloor,
                                        seedClusters: seeds, minimumNextID: minimumNextID)
        clustering.baseThreshold = tuning.clusterThreshold
        clustering.anchoredClusterIDs = anchoredClusterIDs
        clustering.assignMargin = tuning.assignMargin
        clustering.sizeAdaptiveMarginMax = tuning.sizeAdaptiveMarginMax
        clustering.negativeSameThreshold = tuning.negativeSameThreshold
        clustering.rivalAwareMarginGate = flags.rivalAwareMarginGateWhenCalibratedUp
            && threshold > tuning.clusterThreshold
        clustering.rivalAwareSizeMargin = flags.rivalAwareSizeMargin
        clustering.rivalAwareSizeMarginMaxPeople = flags.rivalAwareSizeMarginMaxPeople
        clustering.rivalAlikeMargin = tuning.rivalAlikeMargin
        if flags.capEffectiveThresholdWhenFewPeople {
            clustering.effectiveThresholdCap = threshold
            clustering.effectiveThresholdCapMaxPeople = flags.effectiveThresholdCapMaxPeople
        }
        return clustering
    }
}

/// **名前は「人」に付いている**（ADR-130・純ロジック・テスト対象）。
///
/// アンカー（確認顔・代表写真）の無い命名済み人物は、同一性の後ろ盾が重心の向きだけ。
/// 再クラスタで顔がまるごと別クラスタへ移ったのに名前だけ元の ID に残ると、そこへ流れ込んだ
/// **別人がその名前のアルバムとして表示される**。
///
/// 実害の記録: 「自分の顔のアルバムが、いつの間にか丸ごと娘の顔になっていた。自分の写真は
/// People 9 として追い出されていた」。過半が移った先が無名なら、名前をそちらへ移す。
public enum FaceNameFollowing {

    /// アンカーの無い命名済み人物（再クラスタ前のメンバーを控えておく）。
    public struct Candidate: Sendable, Equatable {
        public let clusterID: Int
        public let name: String
        /// 再クラスタ前にこの人物へ留まっていた顔。
        public let faceIDs: [String]
        public init(clusterID: Int, name: String, faceIDs: [String]) {
            self.clusterID = clusterID
            self.name = name
            self.faceIDs = faceIDs
        }
    }

    public struct Move: Sendable, Equatable {
        public let from: Int
        public let to: Int
        public let name: String
    }

    /// 名前を移すべき組を返す。
    ///
    /// 条件（すべて満たすときだけ移す）:
    /// 1. 元のクラスタに残ったのが**過半に満たない**
    /// 2. 最も多く流れた先が元とは別で、そこに**過半**が入っている
    /// 3. その先が**無名**（名前のある人物を上書きしない）
    ///
    /// ⚠️ 同数で並んだときは**クラスタ ID の小さい方**を選ぶ。旧実装は `Dictionary.max(by:)` で、
    /// 同数のとき結果が**実行ごとに変わり得た**（同じデータで違う人物に名前が移る）。
    /// 稀だが、起きたときに再現できない種類の不具合になる。
    public static func moves(candidates: [Candidate],
                             assignment: [String: Int],
                             isUnnamed: (Int) -> Bool) -> [Move] {
        var out: [Move] = []
        for entry in candidates where !entry.faceIDs.isEmpty {
            var landing: [Int: Int] = [:]
            for faceID in entry.faceIDs {
                let cid = assignment[faceID] ?? FaceClustering.unassigned
                if cid >= 0 { landing[cid, default: 0] += 1 }
            }
            let kept = landing[entry.clusterID] ?? 0
            guard kept * 2 < entry.faceIDs.count else { continue }
            // 同数は ID の小さい方（決定的にする）。
            let best = landing.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first
            guard let best, best.key != entry.clusterID,
                  best.value * 2 >= entry.faceIDs.count,
                  isUnnamed(best.key) else { continue }
            out.append(Move(from: entry.clusterID, to: best.key, name: entry.name))
        }
        return out
    }
}
