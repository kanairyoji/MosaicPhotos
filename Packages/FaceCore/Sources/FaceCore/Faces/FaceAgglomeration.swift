import Accelerate
import Foundation

/// **全体を見渡してから、近い山どうしを順にまとめる**夜間の再クラスタ（純ロジック・テスト対象・ADR-217）。
///
/// ## なぜ要るか
/// 従来の夜間再クラスタは、顔を品質順に 1 枚ずつ「いちばん似ている山」へ入れる逐次方式だった。
/// 山に顔が入るたびに重心（平均の顔）が動くので、父親似の息子の顔が 1 枚入ると重心が息子寄りに
/// なり、次の息子の顔が入りやすくなる——**混入が次の混入を呼ぶ**（ADR-130「自分のアルバムが
/// 丸ごと娘になった」の形）。入れる順番でも結果が変わる。
///
/// ここでは代わりに、山どうしの近さを「**山 A の全員と山 B の全員の、すべての組の類似の平均**」
/// （平均連結）で測り、いちばん近い組から順にまとめる。息子の顔が父親の山に入るには、父親の
/// 写真全部と平均して似ていなければならない——重心が少しずつ動いていく現象が原理的に起きない。
///
/// ## 数万枚で回すための 2 つの工夫
/// 1. **小さな山を先に作る**。「山の全員との平均類似が `microThreshold` 以上」の顔だけを 1 枚ずつ
///    入れる（ほぼ確実に同じ人・連写や同じ日の写真）。山どうしの HAC は山の数で済む。
///    LFW 4,861 顔で「1 枚ずつから全部の組」と結果が完全に一致し、時間は 1/200。
/// 2. **近い相手だけを覚える**（各山 `neighbors` 個）。全部の組の表（2 万山なら数 GB）を持たない。
///    LFW / FG-NET で全部の組と結果が 100% 一致した。
///
/// 平均連結の値は、単位ベクトルの**和**を持っていれば `(和A・和B) / (件数A × 件数B)` で 1 回で出る
/// ——まとめるたびに全員を比べ直す必要が無い。
///
/// ## 守る決まり（まとめてはいけない組）
/// - **種どうし**（名前・確認・代表写真・束ね＝ユーザーが表明した人物）は、どれだけ似ていても
///   まとめない（ADR-153「人物どうしは自動で結合しない」）。
/// - **同じ写真に写っている顔を含む山どうし**（1 枚の写真に同じ人は 1 回しか写らない・ADR-54）。
/// - 呼び出し側の追加の拒否（負例＝「この人ではない」・ADR-45/140）。
///
/// ⚠️ 顔の埋め込みは**クロージャで 1 枚ずつ**取り出す。全顔の `[Float]` を一度に持つと
/// 86k × 512 × 4 バイト ≒ 176MB になる（ADR-6/119/122）。持つのは山ごとの和だけ。
public enum FaceAgglomeration {

    public struct Config: Sendable, Equatable {
        /// 小さな山に入れる線（山の全員との類似の平均）。**高く**置く——ここで混ざると後で直らない。
        public var microThreshold: Float
        /// 山どうしをまとめる下限（平均連結）。
        public var mergeBar: Float
        /// 各山が覚えておく近い相手の数。
        public var neighbors: Int

        public init(microThreshold: Float, mergeBar: Float, neighbors: Int = 30) {
            self.microThreshold = microThreshold
            self.mergeBar = mergeBar
            self.neighbors = neighbors
        }
    }

    /// 割り当てる顔（軽いメタデータだけ）。
    public struct Face: Sendable, Equatable {
        public let faceID: String
        /// 写真（同じ写真の顔は別人）。
        public let photo: String
        public init(faceID: String, photo: String) {
            self.faceID = faceID
            self.photo = photo
        }
    }

    /// 種（ユーザーが表明した人物）。メンバーは既に固定済みで、ここでは動かさない。
    public struct Seed: Sendable, Equatable {
        public let clusterID: Int
        /// 重心を作る（品質フロア以上の）固定メンバー。
        public let memberFaceIDs: [String]
        /// 固定メンバーが写っている写真（同じ写真の顔をこの人物へ入れない）。
        public let photos: Set<String>
        /// 重心を作るメンバーが居ないときの向き（アンカー・保存済みの重心）。
        public let fallbackCentroid: [Float]?

        public init(clusterID: Int, memberFaceIDs: [String], photos: Set<String>,
                    fallbackCentroid: [Float]? = nil) {
            self.clusterID = clusterID
            self.memberFaceIDs = memberFaceIDs
            self.photos = photos
            self.fallbackCentroid = fallbackCentroid
        }
    }

    /// まとめ上がった 1 つの人物。
    public struct Group: Sendable, Equatable {
        /// 種に入ったなら、その種のクラスタ ID。新しい人物なら nil。
        public let seedID: Int?
        /// ここで割り当てた顔（種の固定メンバーは含まない）。入力の順序を保つ。
        public let faceIDs: [String]
    }

    /// 山の要約（追加の拒否を判定するための材料）。
    public struct GroupSummary {
        public let seedID: Int?
        /// 単位ベクトルの平均（正規化していない＝長さが「まとまりの良さ」を表す）。
        public let mean: [Float]
    }

    /// - Parameters:
    ///   - faces: 割り当てる顔。**この順に**小さな山へ入れる（本番は品質の降順）。
    ///   - embedding: faceID → 埋め込み（正規化前でよい）。
    ///   - blocked: 追加の拒否（負例など）。true ならその 2 つの山をまとめない。
    public static func cluster(faces: [Face],
                               seeds: [Seed],
                               embedding: (String) -> [Float]?,
                               config: Config,
                               blocked: ((GroupSummary, GroupSummary) -> Bool)? = nil) -> [Group] {
        var store = GroupStore()

        // 種を先に山として置く（種の山には、あとで顔が入る）。
        for seed in seeds {
            var sum: [Float] = []
            var count = 0
            for id in seed.memberFaceIDs {
                guard let raw = embedding(id) else { continue }
                let v = FaceClustering.normalized(raw)
                if sum.isEmpty { sum = [Float](repeating: 0, count: v.count) }
                guard v.count == sum.count else { continue }
                vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(v.count))
                count += 1
            }
            if count == 0 {
                guard let fallback = seed.fallbackCentroid, !fallback.isEmpty else { continue }
                sum = FaceClustering.normalized(fallback)
                count = 1
            }
            store.append(sum: sum, count: count, seedID: seed.clusterID, photos: seed.photos,
                         faceIDs: [])
        }
        let seedGroupCount = store.count

        // 1) 小さな山。種には入れない（種へは山ごと、平均連結で判定して入れる）。
        let micro = buildMicroGroups(faces: faces, embedding: embedding,
                                     threshold: config.microThreshold, into: &store,
                                     skipFirst: seedGroupCount)

        // 2) 近い相手だけで平均連結の HAC。
        // ⚠️ 平均の行列は小さな山を作るときだけ使う。ここで捨ててピークを下げる
        // （2 万山で 40MB。近い相手探しは和から作り直す）。
        store.means = []
        guard store.count > 1 else { return store.groups(microOrder: micro) }
        merge(&store, config: config, blocked: blocked)
        return store.groups(microOrder: micro)
    }

    // MARK: - 本番のクラスタへの変換

    /// まとめ上がった山から、本番と同じ形のクラスタ（**品質で重み付けした**和・件数）を作る。
    ///
    /// - 種の山は、種の重心（`FaceSeedBuilder` が作った和・件数・見本）へ顔を足す。
    /// - 新しい山は `nextID` から順に ID を振る（山の並び＝決定的）。
    /// - Returns: クラスタと、ここで割り当てた顔 → クラスタ ID。
    public static func materialize(_ groups: [Group], seeds: [FaceClustering.Cluster],
                                   nextID: Int,
                                   embedding: (String) -> [Float]?,
                                   quality: (String) -> Float)
        -> (clusters: [FaceClustering.Cluster], assignment: [String: Int]) {
        var clusters = seeds
        var indexByID = Dictionary(uniqueKeysWithValues: seeds.enumerated().map { ($1.id, $0) })
        var assignment: [String: Int] = [:]
        var next = nextID
        for group in groups {
            let index: Int
            if let seedID = group.seedID, let found = indexByID[seedID] {
                index = found
            } else {
                guard !group.faceIDs.isEmpty else { continue }
                clusters.append(FaceClustering.Cluster(id: next, centroid: [], sum: [], count: 0,
                                                       faceIDs: []))
                index = clusters.count - 1
                indexByID[next] = index
                next += 1
            }
            for id in group.faceIDs {
                guard let raw = embedding(id) else { continue }
                if clusters[index].sum.isEmpty {
                    clusters[index].sum = [Float](repeating: 0, count: raw.count)
                }
                let added = FaceClustering.adding(raw, toSum: clusters[index].sum,
                                                  count: clusters[index].count, quality: quality(id))
                clusters[index].sum = added.sum
                clusters[index].count = added.count
                clusters[index].faceIDs.append(id)
                assignment[id] = clusters[index].id
            }
            if !clusters[index].sum.isEmpty {
                clusters[index].centroid = FaceClustering.normalized(clusters[index].sum)
            }
        }
        // 顔が 1 枚も入らなかった新しい山（埋め込みが壊れていた等）は捨てる。種は残す。
        let seedIDs = Set(seeds.map(\.id))
        clusters.removeAll { $0.count == 0 && !seedIDs.contains($0.id) }
        return (clusters, assignment)
    }

    /// 負例（「この人ではない」）による拒否。**`FaceClustering.place` と同じ式**を山の平均に当てる
    /// （ADR-140: 相対で効かせる）。ここだけ緩いと、逐次の割り当てが拒否した組み合わせを
    /// 夜の再クラスタが通してしまう。負例が無ければ nil（判定を丸ごと省く）。
    public static func negativeBlocker(negatives: [FaceClustering.NegativePair],
                                       sameThreshold: Float)
        -> ((GroupSummary, GroupSummary) -> Bool)? {
        guard !negatives.isEmpty else { return nil }
        return { a, b in
            for (x, y) in [(a, b), (b, a)] {
                let v = FaceClustering.normalized(x.mean)
                let centroid = FaceClustering.normalized(y.mean)
                guard let matched = FaceClustering.firstNegativeMatch(
                    v, centroid: centroid, negatives: negatives, sameThreshold: sameThreshold) else { continue }
                let toRejected = FaceClustering.dot(v, matched.faceCentroid)
                let toCluster = FaceClustering.dot(v, centroid)
                if toRejected >= FaceClustering.negativeDuplicateThreshold
                    || toRejected > toCluster + FaceClustering.negativeMargin { return true }
            }
            return false
        }
    }

    // MARK: - 小さな山

    /// 顔を順に、平均類似が線以上で**写真が重ならない**いちばん近い山へ入れる。無ければ新しい山。
    /// - Returns: 小さな山の索引の並び（作られた順＝出力の順序を決定的にする）。
    private static func buildMicroGroups(faces: [Face], embedding: (String) -> [Float]?,
                                         threshold: Float, into store: inout GroupStore,
                                         skipFirst: Int) -> [Int] {
        var created: [Int] = []
        var dim = store.dimension
        for face in faces {
            guard let raw = embedding(face.faceID) else { continue }
            let v = FaceClustering.normalized(raw)
            if dim == 0 { dim = v.count; store.dimension = dim }
            guard v.count == dim else { continue }
            var best = -1
            var bestScore = threshold
            // 行列×ベクトル 1 回で全部の小さな山との平均類似を出す（数万回の照合を 1 命令に）。
            let scores = store.meanDots(v, from: skipFirst)
            for (offset, score) in scores.enumerated() where score >= bestScore {
                let index = skipFirst + offset
                if store.photos[index].contains(face.photo) { continue }
                if score > bestScore || best < 0 {
                    best = index
                    bestScore = score
                }
            }
            if best >= 0 {
                store.add(v, photo: face.photo, faceID: face.faceID, to: best)
            } else {
                store.append(sum: v, count: 1, seedID: nil, photos: [face.photo],
                             faceIDs: [face.faceID])
                created.append(store.count - 1)
            }
        }
        return created
    }

    // MARK: - 平均連結

    private static func merge(_ store: inout GroupStore, config: Config,
                              blocked: ((GroupSummary, GroupSummary) -> Bool)?) {
        let n = store.count
        // 近い相手（双方向にする＝片方からしか見えない近さを取りこぼさない）。
        var neighbors = store.nearestNeighbors(k: config.neighbors)
        for i in 0..<n {
            for j in neighbors[i] { neighbors[j].insert(i) }
        }
        var heap = PairHeap()
        for i in 0..<n {
            for j in neighbors[i] where i < j {
                heap.push(.init(value: store.linkage(i, j), a: i, b: j))
            }
        }
        var rejected = Set<PairKey>()
        while let top = heap.pop() {
            let (i, j) = (top.a, top.b)
            guard store.alive[i], store.alive[j] else { continue }
            // 古い値（どちらかが既に育った）は捨てる。育ったあとの値は push し直してある。
            let current = store.linkage(i, j)
            guard abs(current - top.value) < 1e-6 else { continue }
            guard current >= config.mergeBar else { break }
            if rejected.contains(PairKey(i, j)) { continue }
            // 決まり: 種どうし・同じ写真・追加の拒否。
            if store.seedID[i] != nil && store.seedID[j] != nil {
                rejected.insert(PairKey(i, j)); continue
            }
            if !store.photos[i].isDisjoint(with: store.photos[j]) {
                rejected.insert(PairKey(i, j)); continue
            }
            if let blocked, blocked(store.summary(i), store.summary(j)) {
                rejected.insert(PairKey(i, j)); continue
            }
            // 種の側を残す（種の ID を保つため）。どちらも種でなければ小さい索引を残す。
            let (keep, drop) = store.seedID[j] != nil ? (j, i) : (i, j)
            store.absorb(drop, into: keep)
            neighbors[keep].formUnion(neighbors[drop])
            neighbors[keep].remove(keep)
            neighbors[keep].remove(drop)
            neighbors[drop] = []
            for k in neighbors[keep] where store.alive[k] {
                neighbors[k].remove(drop)
                neighbors[k].insert(keep)
                heap.push(.init(value: store.linkage(keep, k), a: min(keep, k), b: max(keep, k)))
            }
        }
    }

    // MARK: - 山の置き場

    /// 山ごとの和・件数・写真・顔。**和は単位ベクトルの和**（品質で重み付けしない）——
    /// 平均連結の値が「すべての組の類似の平均」と一致するのはこのときだけ。
    struct GroupStore {
        var dimension = 0
        /// 行優先の和（count × dimension）。
        var sums: [Float] = []
        var counts: [Float] = []
        var seedID: [Int?] = []
        var photos: [Set<String>] = []
        var faceIDs: [[String]] = []
        var alive: [Bool] = []
        /// 平均（sum / count）の行列。小さな山の照合で使う。
        var means: [Float] = []

        var count: Int { counts.count }

        mutating func append(sum: [Float], count: Int, seedID: Int?, photos: Set<String>,
                             faceIDs: [String]) {
            if dimension == 0 { dimension = sum.count }
            guard sum.count == dimension else { return }
            sums.append(contentsOf: sum)
            counts.append(Float(count))
            self.seedID.append(seedID)
            self.photos.append(photos)
            self.faceIDs.append(faceIDs)
            alive.append(true)
            let scale = 1 / Float(max(count, 1))
            means.append(contentsOf: sum.map { $0 * scale })
        }

        mutating func add(_ v: [Float], photo: String, faceID: String, to index: Int) {
            let base = index * dimension
            for d in 0..<dimension { sums[base + d] += v[d] }
            counts[index] += 1
            photos[index].insert(photo)
            faceIDs[index].append(faceID)
            let scale = 1 / counts[index]
            for d in 0..<dimension { means[base + d] = sums[base + d] * scale }
        }

        mutating func absorb(_ drop: Int, into keep: Int) {
            let a = keep * dimension, b = drop * dimension
            for d in 0..<dimension { sums[a + d] += sums[b + d] }
            counts[keep] += counts[drop]
            photos[keep].formUnion(photos[drop])
            faceIDs[keep].append(contentsOf: faceIDs[drop])
            alive[drop] = false
            photos[drop] = []
            faceIDs[drop] = []
        }

        /// 平均連結 = (和A・和B) / (件数A × 件数B)。
        func linkage(_ i: Int, _ j: Int) -> Float {
            var s: Float = 0
            sums.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress! + i * dimension, 1, p.baseAddress! + j * dimension, 1,
                           &s, vDSP_Length(dimension))
            }
            return s / (counts[i] * counts[j])
        }

        func summary(_ i: Int) -> GroupSummary {
            let base = i * dimension
            return GroupSummary(seedID: seedID[i],
                                mean: (0..<dimension).map { sums[base + $0] / counts[i] })
        }

        /// v と、`from` 以降の各山の平均との内積（＝山の全員との類似の平均）。
        func meanDots(_ v: [Float], from start: Int) -> [Float] {
            let rows = count - start
            guard rows > 0, dimension > 0 else { return [] }
            var out = [Float](repeating: 0, count: rows)
            means.withUnsafeBufferPointer { m in
                // (rows × d) × (d × 1)
                vDSP_mmul(m.baseAddress! + start * dimension, 1, v, 1, &out, 1,
                          vDSP_Length(rows), 1, vDSP_Length(dimension))
            }
            return out
        }

        /// 各山の近い相手 k 個（平均連結の値で）。行列積をブロックごとに行い、全部の組の表は持たない。
        func nearestNeighbors(k: Int) -> [Set<Int>] {
            let n = count
            var result = [Set<Int>](repeating: [], count: n)
            guard n > 1, k > 0 else { return result }
            // 平均（和 ÷ 件数）の行列と、その転置（d × n）を作る。
            // ⚠️ 2 万山ならそれぞれ 40MB を一時的に持つ（抜けるときに捨てる）。
            var rowMeans = sums
            for i in 0..<n {
                var scale = 1 / counts[i]
                rowMeans.withUnsafeMutableBufferPointer { p in
                    vDSP_vsmul(p.baseAddress! + i * dimension, 1, &scale,
                               p.baseAddress! + i * dimension, 1, vDSP_Length(dimension))
                }
            }
            var transposed = [Float](repeating: 0, count: n * dimension)
            vDSP_mtrans(rowMeans, 1, &transposed, 1, vDSP_Length(dimension), vDSP_Length(n))
            let block = 256
            var start = 0
            while start < n {
                let rows = min(block, n - start)
                var scores = [Float](repeating: 0, count: rows * n)
                rowMeans.withUnsafeBufferPointer { m in
                    // (rows × d) × (d × n)
                    vDSP_mmul(m.baseAddress! + start * dimension, 1, transposed, 1, &scores, 1,
                              vDSP_Length(rows), vDSP_Length(n), vDSP_Length(dimension))
                }
                for r in 0..<rows {
                    let i = start + r
                    // 上位 k を部分的に選ぶ（同値は索引の小さい方＝決定的）。
                    var top: [(value: Float, index: Int)] = []
                    top.reserveCapacity(k + 1)
                    for j in 0..<n where j != i {
                        let value = scores[r * n + j]
                        if top.count < k {
                            top.append((value, j))
                            if top.count == k { top.sort { $0.value != $1.value ? $0.value > $1.value : $0.index < $1.index } }
                        } else if value > top[k - 1].value {
                            top[k - 1] = (value, j)
                            var p = k - 1
                            while p > 0, top[p].value > top[p - 1].value {
                                top.swapAt(p, p - 1); p -= 1
                            }
                        }
                    }
                    result[i] = Set(top.map(\.index))
                }
                start += rows
            }
            return result
        }

        /// 出力: 種の山（顔が入らなかった種も含む）→ 小さな山が作られた順。
        func groups(microOrder: [Int]) -> [Group] {
            var out: [Group] = []
            for i in 0..<count where alive[i] && seedID[i] != nil {
                out.append(Group(seedID: seedID[i], faceIDs: faceIDs[i]))
            }
            for i in microOrder where alive[i] {
                out.append(Group(seedID: nil, faceIDs: faceIDs[i]))
            }
            return out
        }
    }

    // MARK: - 組の優先度付きキュー

    struct PairKey: Hashable {
        let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    struct Pair {
        let value: Float
        let a: Int
        let b: Int
        /// 大きい値が先。同値は索引の小さい組が先（決定的）。
        func before(_ other: Pair) -> Bool {
            if value != other.value { return value > other.value }
            if a != other.a { return a < other.a }
            return b < other.b
        }
    }

    /// 二分ヒープ（最大値が先頭）。
    struct PairHeap {
        private var items: [Pair] = []

        mutating func push(_ pair: Pair) {
            items.append(pair)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].before(items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Pair? {
            guard let first = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1, right = left + 1
                    var best = parent
                    if left < items.count, items[left].before(items[best]) { best = left }
                    if right < items.count, items[right].before(items[best]) { best = right }
                    if best == parent { break }
                    items.swapAt(parent, best)
                    parent = best
                }
            }
            return first
        }
    }
}
