import PerceptionCore
import Foundation
import MosaicSupport
import os

/// AI アルバムの検索とアルバム情報の組み立て（純ロジック・テスト対象）。
/// 「日付/場所/人物などのハード条件 → 内容語のソフト絞り込み」で、内容語で全滅する場合は
/// ハード条件のみの結果に戻す（タグ未計算でも no-match にしない）。
public struct AIAlbumSearcher {
    let textEmbedder: TextEmbedder?

    private static let log = Logger(subsystem: "com.mosaicphotos.AutoAlbum", category: "aialbum")
    /// 上位帯マージン。最上位スコアからこの幅以内だけ採用（相対バンド）。
    /// 絶対フロア（旧 0.20）は廃止（ADR-24: 閾値レス）＝ライブラリ分布に依存する定数を持たない。
    /// 低スコア帯の候補は証拠ゲート・タグ除外・LLM 審査の積層が刈る。score<=0 だけは無関係として落とす。
    static let semanticMargin: Float = 0.06
    /// 1 アルバムの最大採用数（コサインは弱分離なので上位 K 件で打ち切ってノイズの裾を切る）。
    static let maxResults = 50
    /// 除外の CLIP 対比は**相対判定のみ**（除外概念に肯定より近ければ落とす）。
    /// 絶対しきい値（旧 0.22）はモデルの圧縮された分布と合わず「全写真の 97% を落とす」実障害に
    /// なったため廃止（ADR-24: 閾値レス）。除外の精度はタグ・顔実測・キャプション＝証拠ゲートが担う。

    /// タグとクエリ語の一致数（純・テスト対象）。**単語境界**で照合する（S5・ADR-102）。
    /// 旧実装の双方向 `contains` は「train ⊂ training」級の過剰一致を生んでいた。
    /// 同義・上位語の吸収は文字列いじりではなく語彙接地（`VocabularyGrounding`・重心）が受け持つ。
    static func tagHits(_ tags: [String], terms: [String]) -> Int {
        guard !tags.isEmpty, !terms.isEmpty else { return 0 }
        // 単純な英語複数形だけ吸収する（dogs↔dog・glasses↔glass）。語幹処理はしない。
        func variants(_ token: Substring) -> Set<Substring> {
            var out: Set<Substring> = [token]
            if token.count > 3, token.hasSuffix("es") { out.insert(token.dropLast(2)) }
            if token.count > 2, token.hasSuffix("s") { out.insert(token.dropLast()) }
            return out
        }
        let tagTokens: [Set<Substring>] = tags.map {
            Set($0.lowercased().split { !$0.isLetter && !$0.isNumber }.flatMap(variants))
        }
        let wholeTagVariants: [Set<Substring>] = tags.map { tag in
            variants(Substring(tag.lowercased()))
        }
        var hits = 0
        for term in terms {
            let t = term.lowercased()
            let termTokens = t.split { !$0.isLetter && !$0.isNumber }.map(variants)
            guard !termTokens.isEmpty else { continue }
            let matched: Bool
            if termTokens.count == 1 {
                // ⚠️ 単一語 term は**タグ全体との一致のみ**（複数形の吸収だけ許す）。
                //    トークン内一致にすると "dog" が複合タグ "hot dog" に当たり、犬クエリに
                //    ホットドッグの写真が混ざる（COCO 実測: dog の偽陽性 40 件は全部 hot dog）。
                //    "dog park" のような**関連**タグの吸収は文字列でなく接地（重心）の責務。
                matched = wholeTagVariants.contains { !$0.isDisjoint(with: termTokens[0]) }
            } else {
                // 多語 term は全トークンが同一タグに含まれること（"cherry blossom"）。
                matched = tagTokens.contains { tokens in
                    termTokens.allSatisfy { !$0.isDisjoint(with: tokens) }
                }
            }
            if matched { hits += 1 }
        }
        return hits
    }

    /// 除外語に「人」系の概念が含まれるか。含まれる場合は顔スキャンの実測（faceCount）を
    /// 優先信号として使える（CLIP より確実・ローカルのスキャン済み写真のみ）。
    static func hasPeopleExclusion(_ spec: QuerySpec) -> Bool {
        let peopleWords: Set<String> = ["people", "person", "persons", "human", "humans",
                                        "man", "men", "woman", "women", "child", "children",
                                        "kid", "kids", "face", "faces", "crowd", "portrait"]
        return spec.allContentTerms.exclude.contains { term in
            let t = term.lowercased()
            return peopleWords.contains(t) || t.contains("people") || t.contains("person")
        }
    }

    /// public: 検索品質ハーネス（SearchQualityTests・Recall@k のベースライン計測）が実物の
    /// 検索パイプラインを外部から回すため。アプリ本体は AIAlbumService 経由で使う。
    public init(textEmbedder: TextEmbedder? = nil) {
        self.textEmbedder = textEmbedder
    }

    /// QuerySpec（合成可能・OR/NOT/新ファセット対応）版のバッチ検索。
    /// ハード条件は `QueryEvaluator`（節の OR）で絞り、ソフトは内容語(include)を CLIP で採点する。
    /// `searchWithPool` の薄いラッパ（メンバーのみ返す・採点＝フロア＋マージン＋上位K）。
    func search(baseLite all: [EnrichedPhoto], spec: QuerySpec, now: Date, semanticText: String,
                probes: [String] = [],
                pageSize: Int = AutoAlbumTuning.semanticSearchPageSize,
                faceCounts: [String: Int]? = nil,
                humanCounts: [String: Int] = [:],
                photoTags: [String: [String]] = [:],
                ocrTexts: [String: String] = [:],
                peopleByRefKey: [String: [String]]? = nil,
                signals: QuerySignals = QuerySignals(),
                loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> [EnrichedPhoto] {
        await searchWithPool(baseLite: all, spec: spec, now: now, semanticText: semanticText,
                             probes: probes, pageSize: pageSize, faceCounts: faceCounts,
                             humanCounts: humanCounts,
                             photoTags: photoTags, ocrTexts: ocrTexts, peopleByRefKey: peopleByRefKey,
                             signals: signals,
                             loadPage: loadPage).members
    }

    /// `search(baseLite:spec:)` の本体。増分評価（Phase 2）のために**意味スコアのプール**
    /// （refKey → コサイン・上位 `poolLimit` 件）も返す。プールは永続化され、以後は新規埋め込み分の
    /// スコアだけをマージしてメンバーを更新できる（全ページ再走査をしない）。
    /// - Parameter faceCounts: 顔スキャンの実測（refKey → 顔数・スキャン済みのみ）。
    ///   「人」系の除外があるとき、**顔が実際に写っている写真をハードに除外**する
    ///   （CLIP 対比より確実。未スキャン・クラウド写真は CLIP 対比が受け持つ）。
    /// - Parameter photoTags: シーンタグ台帳（refKey → Vision 分類・精度校正済み）。
    ///   タグ一致は**閾値レス**（写真内順位で付与済み・照合は集合演算）の一次ランキングとして
    ///   意味検索と RRF 融合し、除外語はタグの離散一致でもハード除外する（P1）。
    /// - Parameter probes: FM 生成の言い換えプローブ（解釈時に 1 回生成・永続化）。意味採点は
    ///   主フレーズ＋プローブの max-over-probes＝言い換えの取りこぼしを回収する（ADR-35）。
    /// - Parameter peopleByRefKey: 顔クラスタの**現在の**人物名（live 照合・QueryEvaluator 参照）。
    public func searchWithPool(baseLite all: [EnrichedPhoto], spec: QuerySpec, now: Date, semanticText: String,
                               probes: [String] = [],
                               pageSize: Int = AutoAlbumTuning.semanticSearchPageSize,
                               faceCounts: [String: Int]? = nil,
                               humanCounts: [String: Int] = [:],
                               photoTags: [String: [String]] = [:],
                               ocrTexts: [String: String] = [:],
                               peopleByRefKey: [String: [String]]? = nil,
                               signals: QuerySignals = QuerySignals(),
                               loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> (members: [EnrichedPhoto], pool: [String: Float]) {
        var base = QueryEvaluator.hardFilter(all, spec: spec, now: now,
                                             peopleByRefKey: peopleByRefKey, signals: signals)
        // **実効**内容語（ADR-109）: ハード条件（人物・場所）に接地済みの語は内容語から除く。
        // FM は「バレエの太郎」で content にも "太郎" を入れがちで、そのまま字句照合へ流すと
        // 人物名チャネルが RRF 和集合経由で**バレエ証拠ゼロの太郎の全写真**を通す（AND が OR 化）。
        let includeTerms = spec.effectiveContentTerms.include
        let excludeTerms = spec.allContentTerms.exclude

        // 人物除外は**実測の人数**で判定する（faceCounts が渡された＝人系の除外あり）。
        //
        // ⚠️ 証拠の優先順位と「無い＝いない」の禁止（ADR-100）:
        //    (1) `humanCount`（Vision 上半身検出・夜間タグ付けで全写真に付く・網羅率 約86%）
        //    (2) `faceCounts`（顔スキャン・網羅率 約11%）
        //    どちらにも記録が無い写真は「人がいないと確認できていない」＝**通さない**。
        //    旧実装は `(faceCounts[id] ?? 0) == 0` で、未スキャンの 89% を「人なし」と読んでいた。
        //    COCO 計測では precision 0.490（誤混入 2062 枚）＝アルバムの半分が人物写真だった。
        if let faceCounts {
            base = base.filter { photo in
                if let human = humanCounts[photo.id] { return human == 0 }
                if let faces = faceCounts[photo.id] { return faces == 0 }
                return false   // 証拠なし＝主張できないので入れない（索引が進めば入る）
            }
        }
        // P1: 除外語にタグが一致する写真をハード除外（離散・閾値レス。例:「人が写っていない」×
        // タグ people/person）。タグ未付与の写真は対象外（CLIP 対比が受け持つ）。
        if !excludeTerms.isEmpty && !photoTags.isEmpty {
            base = base.filter { photo in
                guard let tags = photoTags[photo.id] else { return true }
                return Self.tagHits(tags, terms: excludeTerms) == 0
            }
        }

        // 内容の意図が実効的に無い（内容語はあったが全部ハード接地語だった・除外も無い）なら、
        // ハード絞り込みの結果が答え（ADR-109）。英訳文で CLIP band すると「太郎」だけの
        // アルバムが恣意的な帯で欠ける。内容語がもともと無いクエリは従来経路（下の guard）。
        if spec.hasContent && includeTerms.isEmpty && excludeTerms.isEmpty && spec.hasHardConstraints {
            Diagnostics.mark("aialbum: content=hard-grounded only → base \(base.count)")
            return (base, [:])
        }

        // 対策1: 除外があるときの肯定側は include 語（無ければ否定節を落とした英訳文）を使う。
        // 全文には "without people" 等の否定が含まれ、CLIP は否定を理解せず逆に引っ張られる。
        // 選定規則は `QueryEmbedder` に集約（増分評価＝AIAlbumService.queryVectors と同一実装）。
        let phrase = QueryEmbedder.phrase(include: includeTerms, exclude: excludeTerms,
                                          semanticText: semanticText,
                                          preferIncludeTerms: spec.hasGroundedHardTerms)
        let hasPhrase = !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 安全網: ハード条件で全滅したが意味検索の意図(phrase)がある場合、内容のみへ緩和して
        // 「何も出ない」を避ける（解釈器がデータで満たせないハード条件を出した場合の保険）。
        var relaxed = false
        if base.isEmpty && spec.hasHardConstraints && hasPhrase {
            base = spec.excludeScreenshots ? all.filter { !$0.isScreenshot } : all
            relaxed = true
        }

        // 診断: なぜ空かを切り分けるための要約（base/埋め込み/しきい値/融合）。
        var embeddedCount = 0
        var topScore: Float = -1
        var embedderAvailable = false

        guard hasPhrase, !base.isEmpty else {
            Diagnostics.mark("aialbum: early base=\(base.count)/\(all.count) clauses=\(spec.clauses.count) hard=\(spec.hasHardConstraints) phraseEmpty=\(!hasPhrase) excl=\(excludeTerms.count)")
            // フレーズ無し（翻訳保留等）: ハード条件（日付/場所等）があればその絞り込み結果。
            // 旧: 無条件で base を返し、全滅解釈＋翻訳失敗の組で「全 68,512 枚のアルバム」が
            // 生成される実障害になったため、既定は**空**。
            if spec.hasHardConstraints { return (base, [:]) }
            // ⚠️ ただし**除外だけのクエリ**（「犬が写っていない写真」）は、肯定語が無くても
            //    それ自体が有効な選択である（ADR-100）。ここまでで離散のタグ除外・人物実測に
            //    よる絞り込みは済んでいるので base をそのまま返す。以前は空を返しており、
            //    否定を汎用化した直後は「正しく除外はするが 1 枚も出ない」状態だった
            //    （COCO 計測: no-dog / no-car が recall 0）。
            //    「証拠の無い写真まで通す」ことは呼び手の証拠ゲートが防ぐ＝ここでは通してよい。
            //    除外語は決定的レキシコンで接地済み（LLM の失敗では立たない）＝旧障害は再発しない。
            if !excludeTerms.isEmpty { return (base, [:]) }
            return ([], [:])
        }

        // 字句検索は地名/人物に加えて OCR 台帳（写真内テキスト）も引く（photo-info-expansion）。
        let lexical = LexicalSearch.rank(base, keywords: includeTerms, ocrTexts: ocrTexts)

        var semantic: [EnrichedPhoto] = []
        var pool: [String: Float] = [:]
        embedderAvailable = textEmbedder?.isAvailable == true
        // クエリ埋め込み（肯定＋除外語の個別埋め込み）は `QueryEmbedder` に集約
        // （増分評価＝AIAlbumService.queryVectors と同一実装）。
        if let q = await QueryEmbedder(textEmbedder: textEmbedder)
            .embed(phrase: phrase, probes: probes, excludeTerms: excludeTerms) {
            // 採点規則（max-over-probes＋除外の相対判定）は QueryEmbedder.semanticScore に一元化
            // （増分評価＝AIAlbumService.refreshIncremental と同一実装）。
            let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var scored: [(photo: EnrichedPhoto, score: Float)] = []
            scored.reserveCapacity(base.count)
            var excludedByNeg = 0
            var offset = 0
            while true {
                let page = await loadPage(offset, pageSize)
                if page.isEmpty { break }
                for entry in page {
                    guard let photo = baseByID[entry.refKey], let v = ClipMath.decode(entry.clipVector) else { continue }
                    guard let pos = QueryEmbedder.semanticScore(q, photoVector: v) else {
                        excludedByNeg += 1
                        continue
                    }
                    scored.append((photo, pos))
                }
                offset += pageSize
                if page.count < pageSize { break }
            }
            if !q.negatives.isEmpty {
                Diagnostics.mark("aialbum: negFilter terms=\(excludeTerms.count) dropped=\(excludedByNeg)")
            }
            scored.sort { $0.score > $1.score }
            embeddedCount = scored.count
            if let top = scored.first?.score {
                topScore = top
                let cutoff = max(1e-4, top - Self.semanticMargin)   // 相対バンドのみ（フロア廃止）
                semantic = scored.prefix(Self.maxResults).filter { $0.score >= cutoff }.map(\.photo)
            }
            // 増分評価の土台となるプール（上位のみ・小さく永続化）。
            pool = Dictionary(uniqueKeysWithValues:
                scored.prefix(Self.poolLimit).map { ($0.photo.id, $0.score) })
        }

        // P1: タグ一致（一致数降順）を第3のランキングとして融合する。
        var tagMatched: [EnrichedPhoto] = []
        if !includeTerms.isEmpty && !photoTags.isEmpty {
            tagMatched = base
                .map { ($0, Self.tagHits(photoTags[$0.id] ?? [], terms: includeTerms)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            if !tagMatched.isEmpty {
                Diagnostics.mark("aialbum: tagMatch terms=\(includeTerms.count) hits=\(tagMatched.count)")
            }
        }
        let fused = HybridFusion.fuse([lexical, semantic, tagMatched].filter { !$0.isEmpty })
        // 構造化条件がありヒット0なら base を返す（従来）。ただし緩和(relaxed)時は全件を返さず空にする
        // （ハードが本来全滅＝該当なしのため、意味も当たらなければ空が正しい）。
        // 内容の意図（フレーズ）があるのにどの経路（タグ/意味/字句）でも当たらない場合は**空**を返す。
        // 旧: ハード条件があれば base（例: 日付窓の全 7,508 枚）へフォールバックし、「子供」の意図が
        // 消えた巨大アルバムになる実障害。証拠主義（ADR-24）＝索引が進めば自然に埋まる方を選ぶ。
        let result = fused
        Diagnostics.mark("aialbum: base=\(base.count)/\(all.count) hard=\(spec.hasHardConstraints) relaxed=\(relaxed) emb=\(embedderAvailable) scored=\(embeddedCount) top=\(String(format: "%.3f", topScore)) kept=\(semantic.count) lex=\(lexical.count) result=\(result.count)")
        return (result, pool)
    }

    // MARK: - 増分評価（Phase 2・純ロジック＝テスト対象）

    /// プール保持数（メンバー上限より広く取り、マージ後の入れ替わりを安定させる）。
    static let poolLimit = 300

    /// 既存プールへ新規スコアをマージし、上位 `poolLimit` 件に刈り込む（純）。
    static func mergePool(_ existing: [String: Float], adding new: [String: Float]) -> [String: Float] {
        var merged = existing
        for (key, score) in new { merged[key] = score }
        guard merged.count > poolLimit else { return merged }
        let kept = merged.sorted { $0.value > $1.value }.prefix(poolLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// プールから「メンバーに入るべき refKey」を返す（純）。フル評価と同じ
    /// カットオフ規則（top−margin の相対バンド・score>0・上位 K）を適用する。
    static func memberKeys(fromPool pool: [String: Float]) -> [String] {
        guard let top = pool.values.max() else { return [] }
        let cutoff = max(1e-4, top - semanticMargin)
        return pool.filter { $0.value >= cutoff }
            .sorted { $0.value > $1.value }
            .prefix(maxResults)
            .map(\.key)
    }

    /// メンバー写真から AI アルバムの表示情報を組み立てる（純）。
    /// タイトルはユーザー指定を優先し、空なら解釈タイトル→条件文の順で補完する。
    /// - Parameter aesthetics: refKey → 美的スコア（Vision・-1〜1）。カバー選択の加点に使う。
    /// - Parameter usage: refKey → 利用カウンタ（共有/閲覧）。カバー選択の加点に使う。
    static func buildInfo(id: String, title: String, interpretedTitle: String, criteria: String,
                          members: [EnrichedPhoto], aesthetics: [String: Double] = [:],
                          usage: [String: PhotoUsageCounts] = [:]) -> AutoAlbumInfo {
        let (startDate, endDate) = AlbumDates.range(members.map(\.captureDate))
        let people = rankedByFrequency(members.flatMap(\.people))
        let located = members.filter(\.hasCoordinate)
        let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
        let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = !trimmedTitle.isEmpty ? trimmedTitle : (interpretedTitle.isEmpty ? criteria : interpretedTitle)
        return AutoAlbumInfo(
            id: id, strategyID: AIAlbumStrategy.strategyID,
            title: resolved, placeName: resolved, places: [resolved], country: nil, people: people,
            startDate: startDate, endDate: endDate,
            coverRef: pickCoverRef(members, aesthetics: aesthetics, usage: usage),
            memberRefs: members.map(\.id), photoCount: members.count,
            representativeDate: endDate != .distantPast ? endDate : Date(),
            latitude: lat, longitude: lon, criteria: criteria)
    }
}
