import AutoAlbumCore
import Foundation
import MosaicSupport

/// `ConceptExpander` の CLIP 実装（ADR-101）。**タグの重心**（text↔image）で近さを測る。
///
/// ⚠️ 当初はクエリ語とタグ**語同士**の CLIP テキスト類似度で実装したが、実測で不十分だった。
/// CLIP が学習しているのは「画像と説明文が近くなる」ことだけで、テキスト同士の距離は訓練目標に
/// 入っていない。実際、テキスト塔の埋め込みは異方性が強く、どの語も語彙全体と 0.67〜0.83 で並び、
/// `camera` のようなハブ語がほぼ全クエリの上位に出た。Caltech-101 での比較計測:
///
/// | 方式 | 接地できた語 | 正解集合に対する F1 |
/// |---|---|---|
/// | 語同士（text↔text） | 3/10（完全一致のみ） | 0.300 |
/// | **重心（text↔image）** | **10/10** | **0.761** |
///
/// 重心版は「`風景` は `mountain` という**語**に近いか」ではなく
/// 「`風景` は `mountain` タグが付いた**写真たち**に近いか」を問う＝CLIP の設計どおりの使い方。
/// 副産物として、タグの意味が**このライブラリの写真**で定義される（雪山ばかりなら mountain は
/// そういう意味になる）。
///
/// コスト: 画像埋め込みは全写真ぶん既に `PhotoEmbedding` にあるので**新規の推論はゼロ**。
/// 1 回舐めてタグごとに平均するだけ。結果はキャッシュする。
public final class CLIPConceptExpander: ConceptExpander, @unchecked Sendable {

    /// タグ → そのタグが付いた写真の CLIP 画像埋め込み（重心の材料）を供給する seam。
    /// Composition Root（アプリ）が TagStore＋AutoAlbumStore で結線する。
    public typealias CentroidSource = @Sendable ([String]) async -> [String: [Float]]

    private let centroidSource: CentroidSource
    public init(centroidSource: @escaping CentroidSource) {
        self.centroidSource = centroidSource
    }

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "expander")
    private let lock = NSLock()
    private var cachedVocabulary: [String] = []
    private var cachedCentroids: [String: [Float]] = [:]
    /// 実行中の重心構築（後続は合流する）。
    /// ⚠️ これが無いと**並走した呼び出しが全部フル構築**する。実機 diagnostics-46 では
    /// 夜間の finalize 2 本が同時に重心構築へ入り、51k 件の埋め込み走査が 2 本並走した
    /// （`aialbum.centroids` スパン 2 本・どちらも約 30 分の壁時計）。
    private var inFlight: Task<[String: [Float]], Never>?

    public var isAvailable: Bool { MobileCLIP.modelsBundled }

    public func similarities(terms: [String], vocabulary: [String]) async -> [[Double]] {
        guard !terms.isEmpty, !vocabulary.isEmpty, isAvailable else { return [] }
        let centroids = await centroids(for: vocabulary)
        guard !centroids.isEmpty else { return [] }

        var out: [[Double]] = []
        out.reserveCapacity(terms.count)
        for term in terms {
            guard let query = await encodeText(term) else {
                out.append(Array(repeating: 0, count: vocabulary.count))
                continue
            }
            // 重心の無いタグ（枚数不足）は 0＝候補にならない。
            out.append(vocabulary.map { tag in
                guard let c = centroids[tag] else { return 0 }
                return max(0, Double(ClipMath.cosine(query, c)))
            })
        }
        return out
    }

    /// 高原判定用の凝集度 z（S6・ADR-102）。候補（語彙インデックス集合）の重心どうしの平均
    /// コサインが、語彙全体の背景（サンプリングした全ペア平均）からどれだけ突出しているかを返す。
    /// 「animal のような広い語＝候補が互いに近い」と「雑音の高原＝候補がバラバラ」を分離する
    /// （Caltech 実測: animal 2.24 / insect 2.44 vs 雑音語 0.17〜1.11）。
    public func coherenceContext(vocabulary: [String]) async -> CoherenceContext? {
        let centroids = await centroids(for: vocabulary)
        let vecs: [[Float]?] = vocabulary.map { centroids[$0] }
        let present = vecs.indices.filter { vecs[$0] != nil }
        guard present.count >= 8 else { return nil }

        // 背景統計。全ペアは 600 語で 18 万組になるため、決定的な間引きで最大 2 万組に抑える。
        let totalPairs = present.count * (present.count - 1) / 2
        let step = max(1, totalPairs / 20_000)
        var background: [Double] = []
        var pairIndex = 0
        for a in 0..<present.count {
            for b in (a + 1)..<present.count {
                if pairIndex % step == 0,
                   let va = vecs[present[a]], let vb = vecs[present[b]] {
                    background.append(Double(ClipMath.cosine(va, vb)))
                }
                pairIndex += 1
            }
        }
        guard background.count >= 8 else { return nil }
        let mean = background.reduce(0, +) / Double(background.count)
        let variance = background.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(background.count)
        let sd = variance.squareRoot()
        guard sd > 0 else { return nil }

        let setZ: @Sendable ([Int]) -> Double = { indices in
            let valid = indices.compactMap { $0 >= 0 && $0 < vecs.count ? vecs[$0] : nil }
            guard valid.count >= 2 else { return 0 }
            var total = 0.0
            var count = 0
            for i in 0..<valid.count {
                for j in (i + 1)..<valid.count {
                    total += Double(ClipMath.cosine(valid[i], valid[j]))
                    count += 1
                }
            }
            return (total / Double(count) - mean) / sd
        }
        // 限界凝集（S12・精錬用）: 候補 1 件と集合の平均類似の突出。
        let marginalZ: @Sendable (Int, [Int]) -> Double = { candidate, group in
            guard candidate >= 0, candidate < vecs.count, let cv = vecs[candidate] else { return 0 }
            let others = group.compactMap { $0 >= 0 && $0 < vecs.count ? vecs[$0] : nil }
            guard !others.isEmpty else { return 0 }
            let total = others.reduce(0.0) { $0 + Double(ClipMath.cosine(cv, $1)) }
            return (total / Double(others.count) - mean) / sd
        }
        return CoherenceContext(setZ: setZ, marginalZ: marginalZ)
    }

    // MARK: - Private

    private func encodeText(_ text: String) async -> [Float]? {
        guard let tokenizer = CLIPTokenizer.shared else { return nil }
        // ⚠️ 重心を作った側（写真）と揃える必要はないが、表示ラベラ・評価スクリプトと同じ定型文にする。
        return await MobileCLIPRuntime.shared.encodeText(tokenizer.encode("a photo of \(text)"),
                                                         priority: .interactive)
    }

    private func centroids(for vocabulary: [String]) async -> [String: [Float]] {
        lock.lock()
        if cachedVocabulary == vocabulary, !cachedCentroids.isEmpty {
            let cached = cachedCentroids
            lock.unlock()
            return cached
        }
        if let running = inFlight {
            lock.unlock()
            return await running.value   // 構築中なら合流（二重のフル構築をしない）
        }
        let source = centroidSource
        let task = Task { [vocabulary] () -> [String: [Float]] in
            let started = Date()
            let epoch = ProcessSuspension.epoch
            let computed = await source(vocabulary)
            let ms = Date().timeIntervalSince(started) * 1000
            // 中断を跨いだスパンは壁時計汚染なので記録しない（diagnostics-46 で「29 分」と誤読した）。
            if !ProcessSuspension.didSuspend(since: epoch) {
                PerfTrace.logSpan("aialbum.centroids", ms: ms)
            }
            Self.log.info("tag centroids: \(computed.count)/\(vocabulary.count) tags in \(Int(ms))ms"
                          + (ProcessSuspension.didSuspend(since: epoch) ? " (spans suspend)" : ""))
            return computed
        }
        inFlight = task
        lock.unlock()

        let computed = await task.value
        lock.lock()
        inFlight = nil
        if !computed.isEmpty {
            cachedVocabulary = vocabulary
            cachedCentroids = computed
        }
        lock.unlock()
        return computed
    }
}
