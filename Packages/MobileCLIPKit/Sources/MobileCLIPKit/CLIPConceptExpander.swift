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
        lock.unlock()

        let started = Date()
        let computed = await centroidSource(vocabulary)
        let ms = Date().timeIntervalSince(started) * 1000
        PerfTrace.logSpan("aialbum.centroids", ms: ms)
        Self.log.info("tag centroids: \(computed.count)/\(vocabulary.count) tags in \(Int(ms))ms")
        guard !computed.isEmpty else { return [:] }

        lock.lock()
        cachedVocabulary = vocabulary
        cachedCentroids = computed
        lock.unlock()
        return computed
    }
}
