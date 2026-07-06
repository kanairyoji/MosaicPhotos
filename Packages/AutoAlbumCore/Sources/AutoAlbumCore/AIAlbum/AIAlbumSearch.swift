import Foundation
import MosaicSupport
import os

/// AI アルバムの検索とアルバム情報の組み立て（純ロジック・テスト対象）。
/// 「日付/場所/人物などのハード条件 → 内容語のソフト絞り込み」で、内容語で全滅する場合は
/// ハード条件のみの結果に戻す（タグ未計算でも no-match にしない）。
struct AIAlbumSearcher {
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

    /// 証拠ゲート（純・テスト対象）: 除外条件つきアルバムでは、**検証可能な証拠**
    /// （シーンタグ / 顔実測 / キャプション）を 1 つも持たない写真をメンバーにしない。
    /// 「人が写っていない」と主張できない写真を弱い CLIP 対比だけで通すと漏れる（実障害）。
    /// 証拠は夜間バッチで増えるため、アルバムは索引の進行とともに自然に埋まっていく。
    static func evidenceGated(_ members: [EnrichedPhoto],
                              tags: [String: [String]],
                              faceCounts: [String: Int],
                              captions: [String: String]) -> [EnrichedPhoto] {
        members.filter { photo in
            !(tags[photo.id] ?? []).isEmpty
                || faceCounts[photo.id] != nil
                || (captions[photo.id]?.isEmpty == false)
        }
    }

    /// LLM 審査（P2）用の証拠行（純・テスト対象）。写真を見られない審査員に渡す 1 行サマリ。
    static func evidenceLine(index: Int, photo: EnrichedPhoto,
                             tags: [String], caption: String?, faceCount: Int?) -> String {
        var parts: [String] = ["\(index))"]
        if let date = photo.captureDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            parts.append(f.string(from: date))
        }
        if let place = photo.placeName, !place.isEmpty { parts.append(place) }
        if let faceCount { parts.append("faces=\(faceCount)") }
        if !tags.isEmpty { parts.append("tags: " + tags.prefix(8).joined(separator: ", ")) }
        if let caption, !caption.isEmpty { parts.append("caption: " + caption) }
        return parts.joined(separator: " | ")
    }

    /// タグとクエリ語の一致数（純・テスト対象）。部分一致（tag ⊂ term / term ⊂ tag・ci）。
    static func tagHits(_ tags: [String], terms: [String]) -> Int {
        guard !tags.isEmpty, !terms.isEmpty else { return 0 }
        let lowerTags = tags.map { $0.lowercased() }
        var hits = 0
        for term in terms {
            let t = term.lowercased()
            if lowerTags.contains(where: { $0 == t || $0.contains(t) || t.contains($0) }) { hits += 1 }
        }
        return hits
    }

    /// 除外語 → CLIP プロンプト（ゼロショットの定番形）。
    static func excludePrompt(_ term: String) -> String { "a photo of \(term)" }

    /// 除外があるときの**肯定側フレーズ**。include 語があればそれ、無ければ英訳文から
    /// 否定節を落とした先頭部を使う（"A landscape photo without any people." → "A landscape photo"）。
    /// 否定入りの全文を CLIP に渡すと "people" が逆に人物写真を引き上げるため（CLIP は否定を
    /// 理解しない）、肯定側には否定語を残さないことを保証する。
    static func positivePhrase(include: [String], semanticText: String) -> String {
        if !include.isEmpty { return include.joined(separator: ", ") }
        let text = semanticText.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in [" without ", " with no ", " except ", " excluding ", " but no "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let head = String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty { return head }
            }
        }
        return text
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

    init(textEmbedder: TextEmbedder? = nil) {
        self.textEmbedder = textEmbedder
    }

    /// QuerySpec（合成可能・OR/NOT/新ファセット対応）版のバッチ検索。
    /// ハード条件は `QueryEvaluator`（節の OR）で絞り、ソフトは内容語(include)を CLIP で採点する。
    /// 採点・選抜ロジックは既存の `search(baseLite:query:...)` と同一（フロア＋マージン＋上位K）。
    /// ※ 除外内容（not(content)）の減点は次段で対応予定（本段では include のみ採点）。
    func search(baseLite all: [EnrichedPhoto], spec: QuerySpec, now: Date, semanticText: String,
                pageSize: Int = AutoAlbumTuning.semanticSearchPageSize,
                faceCounts: [String: Int]? = nil,
                photoTags: [String: [String]] = [:],
                loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> [EnrichedPhoto] {
        await searchWithPool(baseLite: all, spec: spec, now: now, semanticText: semanticText,
                             pageSize: pageSize, faceCounts: faceCounts, photoTags: photoTags,
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
    func searchWithPool(baseLite all: [EnrichedPhoto], spec: QuerySpec, now: Date, semanticText: String,
                        pageSize: Int = AutoAlbumTuning.semanticSearchPageSize,
                        faceCounts: [String: Int]? = nil,
                        photoTags: [String: [String]] = [:],
                        loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> (members: [EnrichedPhoto], pool: [String: Float]) {
        var base = QueryEvaluator.hardFilter(all, spec: spec, now: now)
        let includeTerms = spec.allContentTerms.include
        let excludeTerms = spec.allContentTerms.exclude

        // 対策2: 顔の実測で「人が写っている」写真を除外（faceCounts が渡された＝人系の除外あり）。
        if let faceCounts {
            base = base.filter { (faceCounts[$0.id] ?? 0) == 0 }
        }
        // P1: 除外語にタグが一致する写真をハード除外（離散・閾値レス。例:「人が写っていない」×
        // タグ people/person）。タグ未付与の写真は対象外（CLIP 対比が受け持つ）。
        if !excludeTerms.isEmpty && !photoTags.isEmpty {
            base = base.filter { photo in
                guard let tags = photoTags[photo.id] else { return true }
                return Self.tagHits(tags, terms: excludeTerms) == 0
            }
        }

        // 対策1: 除外があるときの肯定側は include 語（無ければ否定節を落とした英訳文）を使う。
        // 全文には "without people" 等の否定が含まれ、CLIP は否定を理解せず逆に引っ張られる。
        let trimmedSemantic = semanticText.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase: String
        if !excludeTerms.isEmpty {
            phrase = Self.positivePhrase(include: includeTerms, semanticText: trimmedSemantic)
        } else {
            phrase = trimmedSemantic.isEmpty ? includeTerms.joined(separator: ", ") : trimmedSemantic
        }
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
            Diagnostics.mark("aialbum: early base=\(base.count)/\(all.count) clauses=\(spec.clauses.count) hard=\(spec.hasHardConstraints) phraseEmpty=\(!hasPhrase)")
            // フレーズ無し（翻訳保留等）: ハード条件（日付/場所等）があればその絞り込み結果、
            // 無ければ**空**を返す。旧: 無条件で base を返し、全滅解釈＋翻訳失敗の組で
            // 「全 68,512 枚のアルバム」が生成される実障害になった。
            return (spec.hasHardConstraints ? base : [], [:])
        }

        let lexical = LexicalSearch.rank(base, keywords: includeTerms)

        var semantic: [EnrichedPhoto] = []
        var pool: [String: Float] = [:]
        if let textEmbedder, textEmbedder.isAvailable {
            embedderAvailable = true
            if let vector = await textEmbedder.embed(phrase) {
                // 除外語は個別に埋め込み、画像ごとに「肯定より除外概念に近い／除外類似が高い」を落とす。
                var negVectors: [[Float]] = []
                for term in excludeTerms {
                    if let neg = await textEmbedder.embed(Self.excludePrompt(term)) { negVectors.append(neg) }
                }
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
                        let pos = ClipMath.cosine(vector, v)
                        if !negVectors.isEmpty {
                            let neg = negVectors.map { ClipMath.cosine($0, v) }.max() ?? -1
                            if neg >= pos {   // 相対判定のみ（絶対閾値は廃止・ADR-24）
                                excludedByNeg += 1
                                continue
                            }
                        }
                        scored.append((photo, pos))
                    }
                    offset += pageSize
                    if page.count < pageSize { break }
                }
                if !negVectors.isEmpty {
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
    static func buildInfo(id: String, title: String, interpretedTitle: String, criteria: String,
                          members: [EnrichedPhoto]) -> AutoAlbumInfo {
        let dates = members.compactMap(\.captureDate)
        let people = rankedByFrequency(members.flatMap(\.people))
        let located = members.filter(\.hasCoordinate)
        let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
        let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = !trimmedTitle.isEmpty ? trimmedTitle : (interpretedTitle.isEmpty ? criteria : interpretedTitle)
        return AutoAlbumInfo(
            id: id, strategyID: AIAlbumStrategy.strategyID,
            title: resolved, placeName: resolved, places: [resolved], country: nil, people: people,
            startDate: dates.min() ?? .distantPast, endDate: dates.max() ?? .distantPast,
            coverRef: pickCoverRef(members), memberRefs: members.map(\.id), photoCount: members.count,
            representativeDate: dates.max() ?? Date(), latitude: lat, longitude: lon, criteria: criteria)
    }
}
