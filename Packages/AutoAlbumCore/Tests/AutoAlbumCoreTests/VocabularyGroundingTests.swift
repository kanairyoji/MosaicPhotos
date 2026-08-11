import Foundation
import Testing
@testable import AutoAlbumCore

/// 語彙接地の**選び方の規則**（ADR-101）。近さの計算（CLIP）は seam なのでここでは注入する。
@Suite("VocabularyGrounding")
struct VocabularyGroundingTests {

    /// ⚠️ 語彙は**実運用に近い規模**にする（z スコア判定は標本数に依存し、n が小さいと
    /// 理論上の最大 z が (n-1)/√n までしか出ない＝n=7 では 2.45 が上限で 3.0 に届かない）。
    /// 本番の語彙は約 600 語、COCO 評価は 80 語。ここは 40 語で代表させる。
    private let vocabulary: [String] = (0..<33).map { "filler\($0)" }
        + ["mountain", "beach", "sunset", "city street", "food", "dog", "indoor"]

    /// 指定した語だけ高く、残りは一様に低い分布を作る（実測の形＝突出の有無で判定できる）。
    private func peaked(_ peaks: [String: Double], baseline: Double = 0.30) -> (String) -> [Double] {
        { _ in self.vocabulary.map { peaks[$0] ?? baseline } }
    }

    @Test("語彙に無い広い概念を、実在する複数の語へ展開する")
    func expandsBroadConcept() {
        let g = VocabularyGrounding.ground(
            terms: ["landscape"], vocabulary: vocabulary,
            similarity: peaked(["mountain": 0.90, "beach": 0.88, "sunset": 0.86, "city street": 0.45]))[0]
        #expect(g.isGrounded)
        #expect(!g.isExact)
        #expect(g.expanded == ["mountain", "beach", "sunset"],
                "相対バンド内の上位だけを採る（city street は落ちる）: \(g.expanded)")
    }

    @Test("語彙にそのまま在る語は展開しない（完全一致を最優先）")
    func exactMatchWins() {
        let g = VocabularyGrounding.ground(terms: ["Dog"], vocabulary: vocabulary,
                                           similarity: peaked([:]))[0]
        #expect(g.isExact)
        #expect(g.expanded == ["dog"])
    }

    @Test("区切り違い（空白 vs 下線）も完全一致・展開結果は語彙側の原形")
    func exactMatchNormalizesSeparators() {
        // Vision 識別子は下線形（ballet_dancer）、レキシコンは空白形（ADR-110 追記）。
        // diagnostics-50: 正規化が無く「ballet dancer」が exact にならず接地が deferred された。
        let vocab = (0..<38).map { "filler\($0)" } + ["ballet", "ballet_dancer"]
        let g = VocabularyGrounding.ground(terms: ["ballet dancer"], vocabulary: vocab,
                                           similarity: { _ in [] })[0]
        #expect(g.isExact)
        #expect(g.expanded == ["ballet_dancer"], "タグ照合は語彙の原形で行うため下線形を返す")
    }

    @Test("どれも遠い語は接地しない（いちばんマシな遠い語を拾わない）")
    func doesNotGroundWhenAllFar() {
        // 実測の「landscape → car/bird/train…」に相当する形: どれも僅差で突出が無い。
        let g = VocabularyGrounding.ground(
            terms: ["quantum physics"], vocabulary: vocabulary,
            similarity: { _ in self.vocabulary.enumerated().map { 0.30 + Double($0.offset) * 0.001 } })[0]
        #expect(!g.isGrounded, "遠い語を無理に接地している: \(g.expanded)")
    }

    @Test("語彙が空なら接地しない（索引がまだ無い段階で誤爆しない）")
    func emptyVocabulary() {
        let g = VocabularyGrounding.ground(terms: ["landscape"], vocabulary: [],
                                           similarity: { _ in [] })[0]
        #expect(!g.isGrounded)
    }

    // MARK: - 高原規則（S6・ADR-102）

    /// animal 型: 該当語彙が多すぎて突出しない（z<3）が、上位候補どうしは互いに近い。
    /// 40 語中 10 語が高原（z≈1.7）になる合成分布。
    private var plateauSimilarity: (String) -> [Double] {
        { _ in self.vocabulary.indices.map { $0 < 10 ? 0.90 - Double($0) * 0.001 : 0.30 } }
    }

    @Test("凝集した高原は接地される（animal 型・成長は凝集が切れた所で止まる）")
    func coherentPlateauGrounds() {
        // 高原メンバー（index<10）どうしは凝集・埋め草とは非凝集、という現実的なスタブ。
        let coherence = CoherenceContext(
            setZ: { indices in indices.allSatisfy { $0 < 10 } ? 3.0 : 0.5 },
            marginalZ: { candidate, _ in candidate < 10 ? 3.0 : 0.0 })
        let g = VocabularyGrounding.ground(terms: ["animal"], vocabulary: vocabulary,
                                           similarity: plateauSimilarity,
                                           coherence: coherence)[0]
        #expect(g.isGrounded, "凝集した高原が接地されない")
        #expect(g.expanded.count == 10,
                "高原のメンバー全員を採り、非凝集の埋め草で止まるべき: \(g.expanded.count)")
    }

    @Test("凝集していない高原（雑音）は接地されない")
    func incoherentPlateauStaysUngrounded() {
        let g = VocabularyGrounding.ground(terms: ["nostalgia"], vocabulary: vocabulary,
                                           similarity: plateauSimilarity,
                                           coherence: CoherenceContext(setZ: { _ in 0.5 },
                                                                        marginalZ: { _, _ in 0.5 }))[0]
        #expect(!g.isGrounded, "雑音の高原が接地された: \(g.expanded)")
    }

    @Test("凝集度が測れない環境では高原を接地しない（従来動作の維持）")
    func plateauNeedsCoherence() {
        let g = VocabularyGrounding.ground(terms: ["animal"], vocabulary: vocabulary,
                                           similarity: plateauSimilarity)[0]   // coherenceZ なし
        #expect(!g.isGrounded)
    }

    // MARK: - 畳み方（肯定と否定で扱いを変える）

    @Test("肯定は接地できなくても残す（CLIP のソフト採点が受け持つ）")
    func ungroundedIncludeIsKept() {
        let g = [VocabularyGrounding.Grounded(term: "Nostalgic", expanded: [], isExact: false)]
        #expect(VocabularyGrounding.flatten(g, keepUngrounded: true) == ["nostalgic"])
    }

    /// ⚠️ ここが要。「索引に無い概念が**写っていない**こと」は検証できない。
    /// 除外に使うと「証拠が無いのに除外した気になる」＝ADR-100 で直した誤りの再来になる。
    @Test("否定は接地できなければ捨てる（検証できない除外を作らない）")
    func ungroundedExcludeIsDropped() {
        let g = [VocabularyGrounding.Grounded(term: "Nostalgic", expanded: [], isExact: false)]
        #expect(VocabularyGrounding.flatten(g, keepUngrounded: false).isEmpty)
    }

    @Test("否定も展開される（犬を除外するなら子犬・犬種も除外する）")
    func exclusionExpandsToo() {
        let vocab: [String] = (0..<36).map { "filler\($0)" } + ["puppy", "golden retriever", "cat", "car"]
        let peaks = ["puppy": 0.92, "golden retriever": 0.90, "cat": 0.50]
        let g = VocabularyGrounding.ground(terms: ["dog"], vocabulary: vocab,
                                           similarity: { _ in vocab.map { peaks[$0] ?? 0.30 } })
        let flat = VocabularyGrounding.flatten(g, keepUngrounded: false)
        #expect(flat == ["puppy", "golden retriever"],
                "除外が展開されないと、子犬の写真が『犬なし』に混ざる: \(flat)")
    }

    @Test("重複は畳む（複数の語が同じ語彙へ落ちても 1 回）")
    func deduplicates() {
        let g = [VocabularyGrounding.Grounded(term: "landscape", expanded: ["mountain", "beach"], isExact: false),
                 VocabularyGrounding.Grounded(term: "scenery", expanded: ["beach", "sunset"], isExact: false)]
        #expect(VocabularyGrounding.flatten(g, keepUngrounded: true) == ["mountain", "beach", "sunset"])
    }
}
