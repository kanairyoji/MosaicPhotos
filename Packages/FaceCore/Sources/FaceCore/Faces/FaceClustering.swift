import Accelerate
import Foundation

/// 顔埋め込み（identity 埋め込み・コサイン類似）の**逐次クラスタリング**。
///
/// 背景パイプラインが 1 枚ずつ顔を追加できるよう、各クラスタの重心を保ちながら割り当てる
/// オンライン方式。新しい顔を最も近いクラスタ重心と比較し、`threshold` 以上なら合流、
/// そうでなければ新規クラスタを作る。`assign` は冪等ではなく**追加順に依存**するが、
/// 背景で増分処理する用途に合う（全件再クラスタは `clusterAll` を使う）。
///
/// 埋め込みは内部で L2 正規化してから扱う（コサイン＝内積）。`threshold` は顔モデル依存
/// （ArcFace 系の正規化埋め込みでは同一人物 ~0.4–0.6 / 別人 <0.3 が目安）。
public struct FaceClustering {
    /// 同一クラスタとみなすコサイン下限。
    public let threshold: Float
    /// この品質未満の顔はクラスタへ割り当てない（ぼけ顔・横顔が重心を汚さないように）。
    /// Vision の faceCaptureQuality（0…1）想定。`assign` は -1（未割当）を返す。
    public let qualityFloor: Float

    /// 未割当を表すクラスタ ID（品質フロア未満・負例で全拒否のとき）。
    public static let unassigned = -1

    /// 負例エグゼンプラ（ユーザー修正「この顔はこの人ではない」の記憶・ADR-45）。
    /// `faceCentroid` に近い顔が `wrongCentroid` に近いクラスタへ入ろうとしたら拒否する。
    /// すべて正規化済みで持つ（保存側の埋め込みから復元して渡す）。
    public struct NegativePair: Sendable, Equatable {
        public let faceCentroid: [Float]
        public let wrongCentroid: [Float]
        public init(faceCentroid: [Float], wrongCentroid: [Float]) {
            self.faceCentroid = faceCentroid
            self.wrongCentroid = wrongCentroid
        }
    }

    /// 負例判定のしきい値。`faceCentroid` と入力顔の類似がこれ以上（＝ほぼ同じ人）かつ、
    /// `wrongCentroid` と候補クラスタ重心の類似がこれ以上（＝同じ誤りクラスタ）なら拒否。
    public static let negativeSameThreshold: Float = 0.55
    public static let negativeWrongThreshold: Float = 0.88

    public struct Cluster: Sendable, Equatable {
        public var id: Int
        /// 正規化済みの重心（割り当て比較に使う）。
        public var centroid: [Float]
        /// 重心更新用の生合計（メンバー追加で加算→再正規化）。
        public var sum: [Float]
        public var count: Int
        /// メンバーの faceID（永続層のキー）。
        public var faceIDs: [String]
        /// マルチプロトタイプ（B3・ADR-46）: ユーザーが確認した顔（アンカー）の正規化済み埋め込み。
        /// 割り当ては「重心またはいずれかのアンカーとの最大類似」で判定＝人物内のばらつき
        /// （年代・眼鏡・角度）で単一重心から遠くなった顔でも正しく合流できる。
        public var prototypes: [[Float]] = []
    }

    public private(set) var clusters: [Cluster] = []
    private var nextID = 0

    public init(threshold: Float = 0.45, qualityFloor: Float = 0.15) {
        self.threshold = threshold
        self.qualityFloor = qualityFloor
    }

    /// 既存クラスタから復元する（永続層からの増分クラスタリング用）。`nextID` は最大 id+1 から続ける。
    /// `minimumNextID`: 新規クラスタ ID の下限（再クラスタリングで、削除予定の旧 ID と
    /// 衝突しないよう既存全 ID より先から振るため・B2）。
    public init(threshold: Float = 0.45, qualityFloor: Float = 0.15, seedClusters: [Cluster],
                minimumNextID: Int = 0) {
        self.threshold = threshold
        self.qualityFloor = qualityFloor
        self.clusters = seedClusters
        self.nextID = max((seedClusters.map(\.id).max() ?? -1) + 1, minimumNextID)
    }

    /// 1 顔を割り当てる（品質重み・負例つき・ADR-45）。
    /// - `quality` 未満（フロア）: 割り当てず -1 を返す（顔行は記録されるが重心を汚さない）。
    /// - 重心加算は品質で重み付け（ぼけ顔ほど寄与を小さく）。
    /// - `negatives` で拒否されたクラスタは飛ばして次点へ（全滅なら新規）。
    /// 返り値は割り当てられたクラスタ ID（未割当は -1）。
    // MARK: - 自動プロトタイプ（P2・ADR-56）

    /// クラスタごとに自動維持する代表埋め込みの上限（0 = 無効）。ユーザー確認に頼らず、
    /// 成長期など「1 つの重心では表せない」人物の多様な見た目を代表群で覆う。
    public var autoPrototypeLimit: Int = 0
    /// マージンゲート（ADR-57・0 = 無効）: 1 位クラスタと 2 位クラスタの類似度差がこれ未満
    /// （＝どちらの人物か紛らわしい）の顔は合流させず新規にする。兄弟のような
    /// 「両方にそこそこ似ている」顔の引き込みを防ぐ（FG-NET 実測で F1 0.542→0.585）。
    public var assignMargin: Float = 0
    /// サイズ適応マージン（ADR-58・0 = 無効）: **小さい/新しいクラスタほど合流を厳しく**する。
    /// 合流に要求する実効しきい値を「threshold ＋ sizeMargin(count)」に引き上げる。
    /// count=1 で最大 `sizeAdaptiveMarginMax`、`sizeAdaptiveMatureCount` 以上で 0（成熟クラスタは素の
    /// しきい値）。成長期に分岐した小クラスタが兄弟を吸い込むのを防ぎ、確立した本人には寛容にする。
    public var sizeAdaptiveMarginMax: Float = 0
    public var sizeAdaptiveMatureCount: Int = 11

    /// マージンゲートで弾いた顔（＝1 位と 2 位が紛らわしい顔）の扱い（ADR-67）。
    public enum AmbiguousPolicy: Sendable, Equatable {
        /// 新しいクラスタを作る（v4 までの挙動）。
        /// ⚠️ 家族ライブラリのように「ほぼ全写真が同じ数人」の分布では、*同じ人の別時期の
        /// クラスタ同士*が恒常的に紛らわしいため、曖昧な顔が来るたびに新クラスタが生まれ、
        /// クラスタ数が写真枚数に比例して膨張する（実ライブラリで 3 人 → 2000 人超）。
        case newCluster
        /// どこにも入れない（未割当）。重心を汚さない点は newCluster と同じだが、
        /// **クラスタ数を増やさない**。表示は第2パス（membership のみ）で回収する。
        case leaveUnassigned
    }
    /// 既定は従来挙動（計測で採否を決めるため・ADR-67）。
    public var ambiguousPolicy: AmbiguousPolicy = .newCluster

    /// **競合相手を見るマージン**（ADR-67）。
    ///
    /// マージンゲート（ADR-57）とサイズ適応マージン（ADR-58）は「兄弟のように似た**別人**の
    /// クラスタが近くにあるとき、紛らわしい顔を取り込まない」ための仕掛けだった。しかし
    /// 家族アルバムのように人物が数人しかいないライブラリでは、近くにあるのはたいてい
    /// **同じ人の別時期のクラスタ**であり、そこでゲートが働くと*正しい合流*を止めて
    /// 分裂を量産する（FG-NET 上位3人で分裂 5.3/人・ゲート無効なら 2.3/人）。
    ///
    /// そこで「競合しているクラスタどうしが**互いに似ているか**」を見る:
    /// - 互いに似ている（≥ しきい値）→ 同一人物の別クラスタ同士＝紛らわしくても実害なし → 免除
    /// - 似ていない → 本当に別人が近い＝危険 → 従来どおりゲートを適用
    ///
    /// ライブラリの人数に依存しない判定なので、少人数でも多人数でも同じ規則で動く。
    public var rivalAwareMargin: Bool = false
    /// 「競合どうしが似ている」と判定するバーの上乗せ（実効バー ＝ `threshold + rivalAlikeMargin`）。
    /// 0 だと素のしきい値で判定するが、それでは**別人どうし**も似ていると見なされて誤統合が増える
    /// （FG-NET 82人で純度 0.879→0.656）。免除は「明らかに同一人物」のときだけ効かせる。
    public var rivalAlikeMargin: Float = 0

    /// クラスタサイズに応じた上乗せマージン（純・線形減衰。count>=mature で 0）。
    func sizeMargin(forCount count: Int) -> Float {
        guard sizeAdaptiveMarginMax > 0, count < sizeAdaptiveMatureCount else { return 0 }
        let mature = Float(max(2, sizeAdaptiveMatureCount))
        let frac = (mature - Float(count)) / (mature - 1)   // count=1→1, count=mature→0
        return max(0, min(1, frac)) * sizeAdaptiveMarginMax
    }
    /// 既存の代表とこの類似度未満のときだけ新代表として追加（似た代表を重複させない）。
    public static let prototypeDiversityMax: Float = 0.75
    /// 代表に採用する顔の最低品質（ぼけ顔を代表にしない）。
    public static let prototypeMinQuality: Float = 0.5

    /// メンバー埋め込みから最遠点サンプリングで代表 K 個を選ぶ（再クラスタ時の作り直し用・純）。
    /// 先頭は品質最高の顔、以降は「既存代表との最大類似度が最小」の顔を貪欲に追加。
    public static func selectPrototypes(_ members: [(embedding: [Float], quality: Float)],
                                        limit: Int) -> [[Float]] {
        guard limit > 0 else { return [] }
        let eligible = members.filter { $0.quality >= prototypeMinQuality }
            .map { (normalized($0.embedding), $0.quality) }
        guard let first = eligible.max(by: { $0.1 < $1.1 }) else { return [] }
        var prototypes: [[Float]] = [first.0]
        while prototypes.count < limit {
            var best: (vec: [Float], sim: Float)?
            for (vec, _) in eligible {
                let sim = prototypes.map { dot(vec, $0) }.max() ?? -1
                if best == nil || sim < best!.sim { best = (vec, sim) }
            }
            guard let candidate = best, candidate.sim < prototypeDiversityMax else { break }
            prototypes.append(candidate.vec)
        }
        return prototypes
    }

    /// - Parameter excludedClusterIDs: 合流を許さないクラスタ（**同一写真 cannot-link**：
    ///   1 枚の写真に同じ人物は 1 回しか写らないため、同じ写真の先行顔が入ったクラスタを除外する）。
    @discardableResult
    public mutating func assign(faceID: String, embedding: [Float],
                                quality: Float = 1, negatives: [NegativePair] = [],
                                excludedClusterIDs: Set<Int> = []) -> Int {
        let v = FaceClustering.normalized(embedding)
        if quality < qualityFloor { return FaceClustering.unassigned }

        // 類似度降順で候補を見て、しきい値以上かつ負例に拒否されない最初のクラスタへ合流。
        // 類似度は「重心 or アンカー（確認済みの顔）との最大」（B3 マルチプロトタイプ）。
        let scored = clusters.indices
            .map { (index: $0, sim: FaceClustering.similarity(v, to: clusters[$0])) }
            .sorted { $0.sim > $1.sim }
        // マージンゲート: 上位 2 クラスタが両方しきい値以上で差が小さい＝紛らわしい顔は
        // どちらにも入れない（除外・負例より先に判定する＝cannot-link されたクラスタとの
        // 紛らわしさも「別人と紛らわしい」証拠として扱う）。
        if assignMargin > 0, scored.count >= 2,
           scored[0].sim >= threshold, scored[1].sim >= threshold,
           scored[0].sim - scored[1].sim < assignMargin,
           // 競合どうしが似ている＝同一人物の別クラスタなら、紛らわしくても取り込んでよい。
           !(rivalAwareMargin && clustersAlike(scored[0].index, scored[1].index)) {
            // 曖昧な顔で新クラスタを増やさない方針（ADR-67）。
            if ambiguousPolicy == .leaveUnassigned { return FaceClustering.unassigned }
            let id = nextID
            nextID += 1
            let w = max(quality, 0.01)
            clusters.append(Cluster(id: id, centroid: v, sum: v.map { $0 * w }, count: 1, faceIDs: [faceID]))
            maintainAutoPrototype(v, quality: quality, at: clusters.count - 1)
            return id
        }
        for cand in scored {
            guard cand.sim >= threshold else { break }   // 以降はもっと低い＝すべて閾値未満
            if excludedClusterIDs.contains(clusters[cand.index].id) { continue }   // cannot-link
            // サイズ適応マージン（ADR-58）: 小/新クラスタは実効しきい値を上げて合流を厳しくする。
            // rivalAware: 「別人が近くにいる」ときだけ課す。競合が無い（or 競合が同一人物らしい）
            // なら、小クラスタを育てない理由がないので素のしきい値で合流させる。
            if cand.sim < threshold + sizeMargin(forCount: clusters[cand.index].count),
               !(rivalAwareMargin && !hasDistinctRival(of: cand.index, in: scored)) { continue }
            if FaceClustering.negativeRejects(v, centroid: clusters[cand.index].centroid, negatives: negatives) {
                continue
            }
            let w = max(quality, 0.01)
            for i in clusters[cand.index].sum.indices { clusters[cand.index].sum[i] += v[i] * w }
            clusters[cand.index].count += 1
            clusters[cand.index].faceIDs.append(faceID)
            clusters[cand.index].centroid = FaceClustering.normalized(clusters[cand.index].sum)
            maintainAutoPrototype(v, quality: quality, at: cand.index)
            return clusters[cand.index].id
        }
        // 該当クラスタなし → 新規（sum は品質重み付き＝以後の removing と整合）。
        let id = nextID
        nextID += 1
        let w = max(quality, 0.01)
        clusters.append(Cluster(id: id, centroid: v, sum: v.map { $0 * w }, count: 1, faceIDs: [faceID]))
        maintainAutoPrototype(v, quality: quality, at: clusters.count - 1)
        return id
    }

    /// 第2パス割当のしきい値（membership のみ）。データセット計測（FG-NET/LFW）で決定:
    /// 0.55 で FG-NET は捨てていた顔の 89% を回復（正解 88%）・LFW は 98% 回復（正解 98.5%）。
    /// 重心を汚さないので既存クラスタの純度は不変。
    public static let secondPassThreshold: Float = 0.55

    /// フロア未満で未割当だった顔（横顔・ぶれ等・埋め込みはある）を、**重心を汚さず**最寄りクラスタへ
    /// membership だけ割り当てる（recall 回復・ADR-66）。sum/count/centroid/prototype は変えず faceIDs にだけ
    /// 加える＝クラスタの純度は不変。閾値未満・cannot-link（同一写真の占有）除外は未割当のまま。
    /// 「人が写っているのに People に出ない」を減らす（品質フロアで捨てていた顔を最寄り人物に表示する）。
    public mutating func assignMembershipOnly(faceID: String, embedding: [Float],
                                              excludedClusterIDs: Set<Int> = [],
                                              threshold: Float = secondPassThreshold) -> Int {
        guard !clusters.isEmpty else { return FaceClustering.unassigned }
        let v = FaceClustering.normalized(embedding)
        let scored = clusters.indices
            .map { (index: $0, sim: FaceClustering.similarity(v, to: clusters[$0])) }
            .sorted { $0.sim > $1.sim }
        for cand in scored {
            guard cand.sim >= threshold else { break }
            if excludedClusterIDs.contains(clusters[cand.index].id) { continue }   // 同一写真 cannot-link
            clusters[cand.index].faceIDs.append(faceID)   // membership のみ（重心は不変）
            return clusters[cand.index].id
        }
        return FaceClustering.unassigned
    }

    /// 2 クラスタが互いに似ているか（＝同一人物の別クラスタらしいか）。代表群どうしの最大類似で見る。
    private func clustersAlike(_ i: Int, _ j: Int) -> Bool {
        var best = FaceClustering.similarity(clusters[i].centroid, to: clusters[j])
        for p in clusters[i].prototypes {
            best = max(best, FaceClustering.similarity(p, to: clusters[j]))
        }
        return best >= threshold + rivalAlikeMargin
    }

    /// 候補クラスタの近くに「**別人らしい**競合」がいるか。
    /// しきい値以上の他クラスタのうち、候補と似ていない（＝別人）ものが 1 つでもあれば true。
    private func hasDistinctRival(of index: Int, in scored: [(index: Int, sim: Float)]) -> Bool {
        for other in scored where other.index != index {
            guard other.sim >= threshold else { break }   // scored は降順
            if !clustersAlike(index, other.index) { return true }
        }
        return false
    }

    /// オンラインの自動プロトタイプ維持: 合流した顔が既存代表のどれとも似ていなければ
    /// （多様性しきい値未満）新しい代表として保持する（成長・眼鏡・髪型の変化を代表群で覆う）。
    private mutating func maintainAutoPrototype(_ v: [Float], quality: Float, at index: Int) {
        guard autoPrototypeLimit > 0,
              quality >= Self.prototypeMinQuality,
              clusters[index].prototypes.count < autoPrototypeLimit else { return }
        let maxSim = clusters[index].prototypes.map { Self.dot(v, $0) }.max() ?? -1
        if maxSim < Self.prototypeDiversityMax {
            clusters[index].prototypes.append(v)
        }
    }

    // MARK: - クラスタ連鎖統合（P3・ADR-56）

    /// 代表群（重心＋プロトタイプ）どうしの最大類似度が `threshold` 以上のクラスタ対を
    /// **推移的に**統合する計画を返す（純・Union-Find）。年齢帯で 0-5↔5-10↔10-15 と
    /// 鎖状に繋がれば、直接は似ていない両端も同一人物にまとまる。
    /// - Parameter blocked: 統合してはいけない対（別人記録・共起・命名不一致など）の判定。
    /// - Returns: 旧クラスタ ID → 統合先クラスタ ID（変化がない ID は含まない）。
    public static func chainMergePlan(clusters: [Cluster], threshold: Float,
                                      blocked: (Int, Int) -> Bool = { _, _ in false }) -> [Int: Int] {
        guard clusters.count >= 2 else { return [:] }
        func representatives(_ c: Cluster) -> [[Float]] { [c.centroid] + c.prototypes }
        // Union-Find（代表 ID は小さい方へ寄せる）。
        var parent: [Int: Int] = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0.id) })
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root]! }
            return root
        }
        for i in clusters.indices {
            for j in (i + 1)..<clusters.count {
                let a = clusters[i], b = clusters[j]
                guard !blocked(a.id, b.id) else { continue }
                var best: Float = -1
                for ra in representatives(a) {
                    for rb in representatives(b) {
                        best = max(best, dot(ra, rb))
                    }
                }
                guard best >= threshold else { continue }
                let rootA = find(a.id), rootB = find(b.id)
                if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
            }
        }
        var plan: [Int: Int] = [:]
        for c in clusters {
            let root = find(c.id)
            if root != c.id { plan[c.id] = root }
        }
        return plan
    }

    /// クラスタとの類似度＝重心と全プロトタイプ（アンカー）のうちの最大（B3）。
    static func similarity(_ v: [Float], to cluster: Cluster) -> Float {
        var best = dot(v, cluster.centroid)
        for p in cluster.prototypes {
            best = max(best, dot(v, p))
        }
        return best
    }

    /// 入力顔 `v`（正規化済み）が候補クラスタ重心 `centroid` へ入ることを、負例が拒否するか。
    static func negativeRejects(_ v: [Float], centroid: [Float], negatives: [NegativePair]) -> Bool {
        for n in negatives {
            if dot(v, n.faceCentroid) >= negativeSameThreshold,
               dot(centroid, n.wrongCentroid) >= negativeWrongThreshold {
                return true
            }
        }
        return false
    }

    /// 全顔をまとめてクラスタリングする（純関数。再クラスタ・テスト用）。
    /// ⚠️ 以前は qualityFloor/quality を渡し忘れており、呼び出し側の設定が無視されていた
    /// （本番経路は未使用のため実害なし・API 衛生として修正）。
    public static func clusterAll(_ faces: [(faceID: String, embedding: [Float])],
                                  threshold: Float = 0.45,
                                  qualityFloor: Float = 0.15,
                                  qualities: [String: Float] = [:],
                                  autoPrototypeLimit: Int = 0,
                                  assignMargin: Float = 0,
                                  sizeAdaptiveMarginMax: Float = 0,
                                  ambiguousPolicy: AmbiguousPolicy = .newCluster,
                                  secondPassMembership: Bool = false,
                                  rivalAwareMargin: Bool = false,
                                  rivalAlikeMargin: Float = 0) -> [Cluster] {
        var clustering = FaceClustering(threshold: threshold, qualityFloor: qualityFloor)
        clustering.autoPrototypeLimit = autoPrototypeLimit
        clustering.assignMargin = assignMargin
        clustering.sizeAdaptiveMarginMax = sizeAdaptiveMarginMax
        clustering.ambiguousPolicy = ambiguousPolicy
        clustering.rivalAwareMargin = rivalAwareMargin
        clustering.rivalAlikeMargin = rivalAlikeMargin
        var unassigned: [(faceID: String, embedding: [Float])] = []
        for f in faces {
            let cid = clustering.assign(faceID: f.faceID, embedding: f.embedding,
                                        quality: qualities[f.faceID] ?? 1)
            if cid == unassignedID { unassigned.append(f) }
        }
        // 第2パス（本番 rebuildClusters と同じ・ADR-66）: 未割当を重心を汚さず最寄りへ。
        if secondPassMembership {
            for f in unassigned {
                _ = clustering.assignMembershipOnly(faceID: f.faceID, embedding: f.embedding)
            }
        }
        return clustering.clusters
    }

    /// `unassigned` の別名（`clusterAll` 内でシャドーイングを避けるため）。
    private static let unassignedID = unassigned

    /// 複数クロップの埋め込みを要素平均→再正規化する（マルチクロップ埋め込み・純関数）。
    /// アライメント済み・水平反転・bbox 切り抜きの 3 埋め込みを平均すると、切り抜きの
    /// ゆらぎに対して同一人物の埋め込みが安定する。次元不一致は多数派に合わせず nil。
    public static func averagedEmbedding(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        guard vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            let n = normalized(v)
            for i in sum.indices { sum[i] += n[i] }
        }
        return normalized(sum)
    }

    /// 「人物」とみなすクラスタ（メンバー数 `minFaces` 以上）を多い順に返す。
    public func people(minFaces: Int = 3) -> [Cluster] {
        clusters.filter { $0.count >= minFaces }.sorted { $0.count > $1.count }
    }

    // MARK: - Reassign（付け替え用の重心演算・純関数）

    /// 顔をクラスタ重心（sum/count）へ追加した結果。`assign` と同じく**正規化してから**加算する
    /// （永続層の付け替え＝`FaceStore.reassignFace` がこの規則からずれないよう一元化）。
    public static func adding(_ embedding: [Float], toSum sum: [Float], count: Int,
                              quality: Float = 1) -> (sum: [Float], count: Int) {
        let v = normalized(embedding)
        let w = max(quality, 0.01)   // assign の重み付けと一致（reassign 後も重心が整合）
        // 次元不一致（壊れた埋め込み）でも count は顔の増減に合わせる（DetectedFace 行数と整合）。
        guard v.count == sum.count else { return (sum, count + 1) }
        var s = sum
        for i in s.indices { s[i] += v[i] * w }
        return (s, count + 1)
    }

    /// 2 クラスタの生合計・件数を統合する（人物アルバムの統合用）。重心 = normalize(sum) なので、
    /// 生合計を単純加算すれば加重平均の重心になり、1 顔ずつ `adding` した場合と数学的に等価。
    /// 次元不一致（壊れた sum）のときは件数だけ合算し、多い方の sum を残す（安全側）。
    public static func merging(sumA: [Float], countA: Int,
                               sumB: [Float], countB: Int) -> (sum: [Float], count: Int) {
        guard sumA.count == sumB.count else {
            return (countA >= countB ? sumA : sumB, countA + countB)
        }
        var s = sumA
        for i in s.indices { s[i] += sumB[i] }
        return (s, countA + countB)
    }

    /// 顔をクラスタ重心から除いた結果。最後の 1 顔を除くと nil（＝クラスタ削除の合図）。
    public static func removing(_ embedding: [Float], fromSum sum: [Float], count: Int,
                                quality: Float = 1) -> (sum: [Float], count: Int)? {
        guard count > 1 else { return nil }
        let v = normalized(embedding)
        let w = max(quality, 0.01)
        guard v.count == sum.count else { return (sum, count - 1) }
        var s = sum
        for i in s.indices { s[i] -= v[i] * w }
        return (s, count - 1)
    }

    // MARK: - Math（正規化済みコサイン＝内積）

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -2 }
        // vDSP: 512 次元×数千顔×数百クラスタの照合が本番（夜間再クラスタ）と
        // 精度ハーネスの支配項になるため SIMD 化する（デバッグビルドでも桁で速い）。
        var s: Float = 0
        vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(a.count))
        return s
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-6 else { return v }
        return v.map { $0 / norm }
    }
}
