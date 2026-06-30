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

    public init(threshold: Float = 0.45) { self.threshold = threshold }

    /// 既存クラスタから復元する（永続層からの増分クラスタリング用）。`nextID` は最大 id+1 から続ける。
    public init(threshold: Float = 0.45, seedClusters: [Cluster]) {
        self.threshold = threshold
        self.clusters = seedClusters
        self.nextID = (seedClusters.map(\.id).max() ?? -1) + 1
    }

    /// 1 顔を割り当てる。最も近いクラスタが `threshold` 以上ならそこへ合流、無ければ新規。
    /// 返り値は割り当てられたクラスタ ID。
    @discardableResult
    public mutating func assign(faceID: String, embedding: [Float]) -> Int {
        let v = FaceClustering.normalized(embedding)

        var bestIndex = -1
        var bestSim: Float = -2
        for (i, c) in clusters.enumerated() {
            let sim = FaceClustering.dot(v, c.centroid)
            if sim > bestSim { bestSim = sim; bestIndex = i }
        }

        if bestIndex >= 0, bestSim >= threshold {
            for i in clusters[bestIndex].sum.indices { clusters[bestIndex].sum[i] += v[i] }
            clusters[bestIndex].count += 1
            clusters[bestIndex].faceIDs.append(faceID)
            clusters[bestIndex].centroid = FaceClustering.normalized(clusters[bestIndex].sum)
            return clusters[bestIndex].id
        } else {
            let id = nextID
            nextID += 1
            clusters.append(Cluster(id: id, centroid: v, sum: v, count: 1, faceIDs: [faceID]))
            return id
        }
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
