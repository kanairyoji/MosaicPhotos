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
    }

    public private(set) var clusters: [Cluster] = []
    private var nextID = 0

    public init(threshold: Float = 0.45, qualityFloor: Float = 0.15) {
        self.threshold = threshold
        self.qualityFloor = qualityFloor
    }

    /// 既存クラスタから復元する（永続層からの増分クラスタリング用）。`nextID` は最大 id+1 から続ける。
    public init(threshold: Float = 0.45, qualityFloor: Float = 0.15, seedClusters: [Cluster]) {
        self.threshold = threshold
        self.qualityFloor = qualityFloor
        self.clusters = seedClusters
        self.nextID = (seedClusters.map(\.id).max() ?? -1) + 1
    }

    /// 1 顔を割り当てる（品質重み・負例つき・ADR-45）。
    /// - `quality` 未満（フロア）: 割り当てず -1 を返す（顔行は記録されるが重心を汚さない）。
    /// - 重心加算は品質で重み付け（ぼけ顔ほど寄与を小さく）。
    /// - `negatives` で拒否されたクラスタは飛ばして次点へ（全滅なら新規）。
    /// 返り値は割り当てられたクラスタ ID（未割当は -1）。
    @discardableResult
    public mutating func assign(faceID: String, embedding: [Float],
                                quality: Float = 1, negatives: [NegativePair] = []) -> Int {
        let v = FaceClustering.normalized(embedding)
        if quality < qualityFloor { return FaceClustering.unassigned }

        // 類似度降順で候補を見て、しきい値以上かつ負例に拒否されない最初のクラスタへ合流。
        let scored = clusters.indices
            .map { (index: $0, sim: FaceClustering.dot(v, clusters[$0].centroid)) }
            .sorted { $0.sim > $1.sim }
        for cand in scored {
            guard cand.sim >= threshold else { break }   // 以降はもっと低い＝すべて閾値未満
            if FaceClustering.negativeRejects(v, centroid: clusters[cand.index].centroid, negatives: negatives) {
                continue
            }
            let w = max(quality, 0.01)
            for i in clusters[cand.index].sum.indices { clusters[cand.index].sum[i] += v[i] * w }
            clusters[cand.index].count += 1
            clusters[cand.index].faceIDs.append(faceID)
            clusters[cand.index].centroid = FaceClustering.normalized(clusters[cand.index].sum)
            return clusters[cand.index].id
        }
        // 該当クラスタなし → 新規（sum は品質重み付き＝以後の removing と整合）。
        let id = nextID
        nextID += 1
        let w = max(quality, 0.01)
        clusters.append(Cluster(id: id, centroid: v, sum: v.map { $0 * w }, count: 1, faceIDs: [faceID]))
        return id
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
    public static func clusterAll(_ faces: [(faceID: String, embedding: [Float])],
                                  threshold: Float = 0.45) -> [Cluster] {
        var clustering = FaceClustering(threshold: threshold)
        for f in faces { clustering.assign(faceID: f.faceID, embedding: f.embedding) }
        return clustering.clusters
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

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -2 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
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
