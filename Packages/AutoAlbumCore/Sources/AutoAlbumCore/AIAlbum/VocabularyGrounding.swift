import Foundation

/// クエリ語を**索引に実在する語彙へ落とす**汎用機構（純ロジック・テスト対象）。
///
/// 動機（ADR-101）: 「風景」は `landscape / scenery / outdoor` に展開されるが、索引側の
/// シーンタグに `landscape` は無く、実際には `mountain` / `beach` / `sunset` として入っている。
/// 一方で `outdoor` は**被写体ではなくカテゴリ**なので、街中でも駐車場でも当たってしまう。
/// 結果、タグ照合は「広すぎるものだけ拾い、狭くて確実なものは取りこぼす」最悪の当たり方をしていた
/// （実測: `mountain` も `beach` も「風景」に一致しない一方、`outdoor` は一致する）。
///
/// 個別に「風景→山,海,…」と書くのは語彙の数だけ破綻するので、**語彙の側から決める**:
/// クエリ語と、台帳に実在するタグとの意味的な近さを測り、上位を採る。近さの計算は seam
/// （本番は CLIP テキスト塔）で、ここは**選び方の規則**だけを持つ。
///
/// 場所・人物では既に「カタログから選ばせる」規律があり（`AIAlbumCatalog`）、
/// これはその規律を内容語へ広げたもの。
public enum VocabularyGrounding {

    /// 1 語の接地結果。
    public struct Grounded: Equatable, Sendable {
        /// 元の語（LLM/レキシコンが出した語）。
        public let term: String
        /// 索引に実在する語へ展開した結果（空＝接地できなかった）。
        public let expanded: [String]
        /// 語彙にそのまま存在したか（＝展開ではなく完全一致）。
        public let isExact: Bool
        /// 接地できたか。**否定に使ってよいかの判断もこれで行う**（不在は検証できないため）。
        public var isGrounded: Bool { !expanded.isEmpty }
    }

    /// 採用する上位件数の上限。増やすほど recall は上がるが、遠い語まで拾って precision が落ちる。
    public static let maxExpansion = 6
    /// 採用する幅（突出型・最上位から標準偏差の何倍まで）。分布で決めるので尺度に依存しない。
    /// ⚠️ 1.0 は保守的すぎた（Caltech 実測: food が pizza 1 件で R=0.21、lobster/strawberry を
    /// 取りこぼす）。パラメータ掃引（peak×plateau の 9 組・雑音語の門が開かないことを確認済み）で
    /// 2.0 を採用＝広い語マクロ F1 0.669 → 0.810。
    public static let relativeMargin = 2.0

    // MARK: 高原（広い語）の採用規則（S6・ADR-102）

    /// 「凝集した高原」と認める下限 z。animal は 1.80（Caltech 実測）なのでこれより下に置く。
    public static let broadMinZScore = 1.5
    /// 高原の**凝集度** z の下限。上位候補どうしが画像空間で互いに近いか（背景の全ペア平均に
    /// 対する突出）。実測: animal 2.24 / insect 2.44 に対し、雑音語は nostalgia 0.17 /
    /// happiness 0.27 / software 0.19 / freedom 1.11 / delicious 0.95——2.0 で完全に分離する。
    /// ⚠️ 分布の形（z・MAD）だけでは「一貫した高原」と「雑音の高原」は区別できない
    /// （animal の MAD-z は 1.51 と通常 z より低い）。意味情報＝候補どうしの距離が要る。
    public static let plateauCoherenceZ = 2.0
    /// 高原時の採用幅と上限。掃引の結果 1.5sd を採用（animal F1 0.746 → 0.902。minaret 等
    /// 2 件の混入と引き換えに 16 クラスの動物を回収＝F1 で明確に得）。
    public static let plateauMargin = 1.5
    public static let broadMaxExpansion = 40

    // MARK: 凝集精錬（S12）: band 選択の混入を刈り、裾を伸ばす

    /// 精錬を**適用してよい**グループ凝集 z の下限。乗り物のような**視覚的に不均質**な正解群
    /// （車・飛行機・船は互いに似ていない＝coh_z 0.15）に精錬を掛けると壊れる（実測 F1 0.4→0.25）。
    /// グループ自体が画像空間で一貫しているときだけ精錬する。
    public static let refineGate = 1.0
    /// 刈り込み: 選択集合の他メンバーとの限界凝集 z がこれ未満の混入を除く（最類似の 1 件は常に残す）。
    /// bird の band に混入した minaret（鳥たちと似ていない）を落とす（実測 F1 0.833→0.909）。
    public static let pruneBar = 0.75
    /// 成長: band の続き（類似度順）を、グループとの限界凝集 z がこれ以上の間だけ足す。
    /// food の裾（strawberry・crab）を band の外から回収する（実測 F1 0.667→0.800）。
    public static let growBar = 1.25
    /// 最上位が「分布から突出している」と認める z スコア。これ未満は接地失敗とする。
    ///
    /// ⚠️ 絶対しきい値を使わない理由（実測・ADR-101）: 類似度の絶対値はモデルと語彙に依存する。
    /// CLIP テキスト塔の実測では、どの語も語彙全体と 0.67〜0.83 の高い値で並び（異方性）、
    /// 絶対値では区別できなかった。「他と比べて突出しているか」なら尺度に依存しない。
    /// 実測の z: pizza 6.07 / train 5.00 / dog 4.31 / people 3.82（いずれも正しい接地）に対し、
    /// landscape 1.68 / scenery 1.76（語彙に相当物が無く、上位は car・bird などの雑音）。
    public static let minTopZScore = 3.0

    /// 語彙へ接地する。
    /// - Parameters:
    ///   - terms: 接地したい語（include / exclude の両方に使う）。
    ///   - vocabulary: 索引に**実在する**語（台帳のタグ）。
    ///   - similarity: 語 × 語彙 の意味的近さ（0〜1）。本番は CLIP テキスト塔。
    ///     語彙と同数の配列を返すこと。
    /// - Parameter coherence: 凝集の計算（集合 z＋限界 z）。本番は重心どうしのコサイン
    ///   （`CLIPConceptExpander`）。nil なら高原規則・精錬は使わない（従来＝突出のみ）。
    public static func ground(terms: [String],
                              vocabulary: [String],
                              similarity: (String) -> [Double],
                              coherence: CoherenceContext? = nil) -> [Grounded] {
        let lowerVocab = vocabulary.map { $0.lowercased() }
        return terms.map { term in
            let t = term.lowercased()
            // 1) 語彙にそのまま在る（または語彙側が完全に含む）なら、それが最良の接地。
            if let exact = lowerVocab.first(where: { $0 == t }) {
                return Grounded(term: term, expanded: [exact], isExact: true)
            }
            // 2) 意味的に近い語を上位から採る。
            guard !vocabulary.isEmpty else {
                return Grounded(term: term, expanded: [], isExact: false)
            }
            let scores = similarity(term)
            guard scores.count == vocabulary.count else {
                return Grounded(term: term, expanded: [], isExact: false)
            }
            let mean = scores.reduce(0, +) / Double(scores.count)
            let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scores.count)
            let sd = variance.squareRoot()
            guard sd > 0 else { return Grounded(term: term, expanded: [], isExact: false) }
            let rankedIndices = scores.indices.sorted { scores[$0] > scores[$1] }
            let top = scores[rankedIndices[0]]
            let z = (top - mean) / sd

            // 採用上限を判定する。
            // (a) 突出（z≥3）: pizza 6.9 / dog 4.3 など＝狭い概念が語彙に相当物を持つ形。
            // (b) 凝集した高原（1.5≤z<3 かつ凝集度 z≥2）: animal など＝該当語彙が多すぎて
            //     突出しない形。上位候補どうしが画像空間で互いに近ければ「一貫した群」と
            //     判定できる（雑音の高原は候補どうしがバラバラ＝実測で完全分離・S6）。
            let cap: Int
            let margin: Double
            if z >= minTopZScore {
                cap = maxExpansion
                margin = relativeMargin
            } else if z >= broadMinZScore, let coherence {
                let probe = Array(rankedIndices.prefix(maxExpansion))
                guard coherence.setZ(probe) >= plateauCoherenceZ else {
                    return Grounded(term: term, expanded: [], isExact: false)
                }
                cap = broadMaxExpansion
                margin = plateauMargin
            } else {
                // 語彙に相当するものが無い＝接地できない。CLIP のソフト採点に委ねる（否定には使わない）。
                return Grounded(term: term, expanded: [], isExact: false)
            }
            // 採用幅は分布で決める（上位から sd 幅ぶん）。
            var selected = rankedIndices.prefix(cap).filter { scores[$0] >= top - sd * margin }
            // 凝集精錬（S12）: グループ自体が視覚的に一貫しているときだけ、
            // (a) 低凝集の混入を刈り（bird の minaret）、(b) band の裾を伸ばす（food の strawberry）。
            // ⚠️ 不均質な正解群（vehicle＝車・飛行機・船）に掛けると壊れるので gate で守る。
            if let coherence, selected.count >= 2, coherence.setZ(selected) >= refineGate {
                if selected.count > 2 {
                    selected = selected.enumerated().filter { k, c in
                        k == 0 || coherence.marginalZ(c, selected.filter { $0 != c }) >= pruneBar
                    }.map(\.1)
                }
                for candidate in rankedIndices where !selected.contains(candidate) {
                    if selected.count >= broadMaxExpansion { break }
                    guard coherence.marginalZ(candidate, selected) >= growBar else { break }
                    selected.append(candidate)
                }
            }
            return Grounded(term: term, expanded: selected.map { lowerVocab[$0] }, isExact: false)
        }
    }

    /// QuerySpec の内容語（include/exclude）を接地して置き換える（本番＝`AIAlbumInterpreter` と
    /// 評価ハーネスが**同一実装**を通るための入口・ADR-102）。
    /// - 肯定: 接地できた語は展開、できなかった語はそのまま残す（CLIP のソフト採点が受け持つ）。
    /// - 否定: 接地できた語だけ残す（索引に無い概念の不在は検証できない・ADR-100）。
    public static func apply(spec: QuerySpec,
                             vocabulary: [String],
                             similarity: (String) -> [Double],
                             coherence: CoherenceContext? = nil) -> QuerySpec {
        let include = spec.allContentTerms.include
        let exclude = spec.allContentTerms.exclude
        guard !include.isEmpty || !exclude.isEmpty, !vocabulary.isEmpty else { return spec }
        let groundedInclude = ground(terms: include, vocabulary: vocabulary,
                                     similarity: similarity, coherence: coherence)
        let groundedExclude = ground(terms: exclude, vocabulary: vocabulary,
                                     similarity: similarity, coherence: coherence)
        let newInclude = flatten(groundedInclude, keepUngrounded: true)
        let newExclude = flatten(groundedExclude, keepUngrounded: false)
        var out = spec
        if newInclude != include { out = QuerySpecSanitizer.withIncludeTerms(out, terms: newInclude) }
        if newExclude != exclude { out = QuerySpecSanitizer.replacingExclusions(out, terms: newExclude) }
        return out
    }

    /// 接地結果を検索語へ畳む。
    /// - Parameter keepUngrounded: 接地できなかった語を残すか。
    ///   **肯定は残す**（CLIP のソフト採点が受け持てる）が、**否定は残さない**
    ///   ——「索引に無い概念が写っていないこと」は検証できないので、除外条件にすると
    ///   「証拠が無いのに除外した気になる」＝旧障害と同じ誤りになる（ADR-100）。
    public static func flatten(_ grounded: [Grounded], keepUngrounded: Bool) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for g in grounded {
            let terms = g.isGrounded ? g.expanded : (keepUngrounded ? [g.term.lowercased()] : [])
            for t in terms where seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}

/// 凝集の計算（S6/S12）。背景統計（全ペア平均・sd）は実装側で前計算しクロージャに閉じる。
public struct CoherenceContext: Sendable {
    /// 集合の凝集 z: 集合内の平均相互類似が背景からどれだけ突出しているか（高原判定・精錬 gate）。
    public let setZ: @Sendable ([Int]) -> Double
    /// 限界凝集 z: 候補 1 件と集合の平均類似の突出（刈り込み・成長の判定）。
    public let marginalZ: @Sendable (Int, [Int]) -> Double

    public init(setZ: @escaping @Sendable ([Int]) -> Double,
                marginalZ: @escaping @Sendable (Int, [Int]) -> Double) {
        self.setZ = setZ
        self.marginalZ = marginalZ
    }
}

/// クエリ語と語彙の意味的な近さを返す seam。本番は CLIP テキスト塔（`MobileCLIPKit`）。
/// ⚠️ 語彙側の埋め込みは使い回す前提（毎回 300〜1500 語をエンコードしない）。
public protocol ConceptExpander: Sendable {
    /// 利用可能か（CLIP 未同梱なら false＝接地せず従来どおり素通しする）。
    var isAvailable: Bool { get }
    /// `terms` の各語について、`vocabulary` の各語との近さ（0〜1）を返す。
    /// 戻り値は `terms` と同じ順・各要素は `vocabulary` と同じ長さ。
    func similarities(terms: [String], vocabulary: [String]) async -> [[Double]]
    /// 凝集の計算（高原判定・精錬）。nil なら高原規則・精錬は使われない。
    func coherenceContext(vocabulary: [String]) async -> CoherenceContext?
    /// 重心が**キャッシュ済み**か（ADR-110）。false のとき `similarities` を呼ぶと
    /// コールド構築（数十分）が走り得る＝作成直後の即時本番化ではキャッシュ済みのときだけ接地する。
    var hasCachedCentroids: Bool { get }
}

public extension ConceptExpander {
    func coherenceContext(vocabulary: [String]) async -> CoherenceContext? { nil }
    var hasCachedCentroids: Bool { true }
}
