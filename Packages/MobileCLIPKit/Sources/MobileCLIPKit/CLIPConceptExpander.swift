import AutoAlbumCore
import Foundation
import MosaicSupport

/// `ConceptExpander` の CLIP 実装（ADR-101）。
///
/// クエリ語と、台帳に実在するタグ語彙との意味的な近さを CLIP テキスト塔で測る。
/// これにより「風景 → mountain / beach / sunset」のような展開が、**語彙の側から**
/// 決まる（個別に対応表を書かない）。同じ仕組みで否定語も展開されるので、
/// 「犬が写っていない」は子犬や犬種も除外できる。
///
/// ⚠️ 語彙側の埋め込みは**使い回す**。語彙は 600 語程度あり、毎回エンコードすると
/// 1 語 ≈ 数十ms として数十秒かかる。語彙が変わったときだけ作り直す
/// （`CLIPDisplayLabeler` が約300語で同じことをしている＝実績のある形）。
public final class CLIPConceptExpander: ConceptExpander, @unchecked Sendable {
    public init() {}

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "expander")
    private let lock = NSLock()
    /// 語彙の並びをキーにした埋め込みキャッシュ（語彙が変われば作り直す）。
    private var cachedVocabulary: [String] = []
    private var cachedVectors: [[Float]] = []

    public var isAvailable: Bool { MobileCLIP.modelsBundled }

    public func similarities(terms: [String], vocabulary: [String]) async -> [[Double]] {
        guard !terms.isEmpty, !vocabulary.isEmpty, isAvailable else { return [] }
        guard let vocabVectors = await vocabularyVectors(vocabulary) else { return [] }

        var out: [[Double]] = []
        out.reserveCapacity(terms.count)
        for term in terms {
            guard let vector = await encode(term) else {
                out.append(Array(repeating: 0, count: vocabulary.count))
                continue
            }
            // CLIP の埋め込みは L2 正規化済み＝内積がコサイン。負値は 0 に潰す（0〜1 の契約）。
            out.append(vocabVectors.map { max(0, Double(ClipMath.cosine(vector, $0))) })
        }
        return out
    }

    // MARK: - Private

    private func encode(_ text: String) async -> [Float]? {
        guard let tokenizer = CLIPTokenizer.shared else { return nil }
        // ⚠️ 素の単語ではなく CLIP の学習分布に近い定型文にする（表示ラベラと同じ規則）。
        return await MobileCLIPRuntime.shared.encodeText(tokenizer.encode("a photo of \(text)"),
                                                         priority: .interactive)
    }

    private func vocabularyVectors(_ vocabulary: [String]) async -> [[Float]]? {
        lock.lock()
        if cachedVocabulary == vocabulary, !cachedVectors.isEmpty {
            let cached = cachedVectors
            lock.unlock()
            return cached
        }
        lock.unlock()

        let started = Date()
        var vectors: [[Float]] = []
        vectors.reserveCapacity(vocabulary.count)
        for word in vocabulary {
            // 中断されたら諦める（作成時の 1 回だけの処理だが、前面を長く占有しない・ADR-98）。
            if Task.isCancelled { return nil }
            guard let v = await encode(word), !v.isEmpty else { return nil }
            vectors.append(v)
        }
        let ms = Date().timeIntervalSince(started) * 1000
        PerfTrace.logSpan("aialbum.vocabEmbed", ms: ms)
        Self.log.info("vocabulary embedded: \(vocabulary.count) words in \(Int(ms))ms")

        lock.lock()
        cachedVocabulary = vocabulary
        cachedVectors = vectors
        lock.unlock()
        return vectors
    }
}
