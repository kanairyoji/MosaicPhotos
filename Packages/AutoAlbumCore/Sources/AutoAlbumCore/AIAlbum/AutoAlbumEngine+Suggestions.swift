import Foundation

// MARK: - AI アルバム作成のサジェスト＋接地プレビュー（コンポーザー支援・ADR-37）

/// サジェストチップの内容（すべて**確実にヒットする語だけ**を出す）:
/// 人物＝命名済み顔クラスタ / 場所＝カタログ実在の地名（頻度順）/
/// よく写るもの＝頻出タグ∩レキシコン（日本語表示・接地保証）/ 日付＝パーサが確実に解釈する定型。
public struct AIAlbumSuggestions: Sendable, Equatable {
    public var people: [String] = []
    public var places: [String] = []
    public var visualWords: [String] = []   // 日本語（レキシコン代表語）
    public var dateWords: [String] = []     // 定型（去年・今年 等）
    public init() {}
    public var isEmpty: Bool { people.isEmpty && places.isEmpty && visualWords.isEmpty && dateWords.isEmpty }
}

/// 入力テキストの**接地プレビュー**（どう解釈されたかの色付きチップ＋ハード条件のヒット件数）。
/// 表示は本番と同じ決定的レイヤー（PersonNameGrounder / レキシコン / RelativeDateParser / カタログ照合）
/// の流用なので、プレビューと実際の検索が乖離しない。
public struct AIAlbumGroundingPreview: Sendable, Equatable {
    public struct Chip: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case person, place, visual, date }
        public let kind: Kind
        public let text: String
        public var id: String { "\(kind.rawValue)|\(text)" }
        public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
    }
    public var chips: [Chip] = []
    /// ハード条件（人物/場所/日付）に合致する枚数。ハード条件が無いときは nil（表示しない）。
    public var hardHitCount: Int?
    public init() {}
}

/// サジェスト/プレビュー用のライブラリスナップショット。
/// 失効は時間でなく**件数変化**で判定する（A5）: enrichment 総数と埋め込み済み数が
/// 変わらない限り再利用（COUNT クエリ 2 本 ≪ 全メタ再フェッチ）。夜間バッチが進んだ
/// 次のコンポーザー表示で自然に再構築される。
struct AIAlbumSuggestionSnapshot {
    let lite: [EnrichedPhoto]
    let catalog: AIAlbumCatalog
    let people: [String]           // 命名済み顔クラスタのフルネーム
    let topTags: [String]
    let builtAt: Date
    let enrichmentCount: Int       // 構築時の取り込み済み写真数
    let embeddedCount: Int         // 構築時の埋め込み済み写真数
}

extension AutoAlbumEngine {

    /// スナップショットの取得。件数（取り込み済み・埋め込み済み）が変わっていなければ
    /// キャッシュを再利用する（A5・COUNT クエリ 2 本で判定）。初回・変化時はライブラリ
    /// 全メタ＋カタログ＋頻出タグを構築する。
    private func suggestionData() async -> AIAlbumSuggestionSnapshot {
        async let enrichmentCountTask = store.enrichmentCount()
        async let embeddedCountTask = store.embeddedCount()
        let (enrichmentCount, embeddedCount) = (await enrichmentCountTask, await embeddedCountTask)
        if let cached = suggestionSnapshot,
           cached.enrichmentCount == enrichmentCount, cached.embeddedCount == embeddedCount {
            return cached
        }
        let lite = await store.allEnrichedPhotosLite()
        async let tags = tagStore.topTags(limit: 40)
        async let people = aiService.namedPeopleProvider?() ?? []
        let catalog = await Task.detached(priority: .userInitiated) { AIAlbumCatalog.build(from: lite) }.value
        let snapshot = AIAlbumSuggestionSnapshot(lite: lite, catalog: catalog,
                                                 people: await people, topTags: await tags,
                                                 builtAt: Date(),
                                                 enrichmentCount: enrichmentCount,
                                                 embeddedCount: embeddedCount)
        suggestionSnapshot = snapshot
        return snapshot
    }

    /// コンポーザーのサジェストチップ（人物・場所・よく写るもの・日付の定型）。
    public func albumSuggestions() async -> AIAlbumSuggestions {
        let data = await suggestionData()
        var out = AIAlbumSuggestions()
        out.people = Array(data.people.prefix(8))
        out.places = Array(data.catalog.places.filter { !$0.isEmpty }.prefix(8))
        // 頻出タグをレキシコンで日本語に逆引き（対応が無いタグは出さない＝表示も接地も保証される）。
        var seen = Set<String>()
        out.visualWords = data.topTags.compactMap { JapaneseVisualLexicon.japaneseLabel(forTag: $0) }
            .filter { seen.insert($0).inserted }
        out.visualWords = Array(out.visualWords.prefix(8))
        out.dateWords = ["去年", "今年", "一昨年"]
        return out
    }

    /// 入力テキストの接地プレビュー（色付きチップ＋ハード条件のヒット件数）。
    /// タイプごとに呼ばれる想定（呼び出し側で debounce）。スナップショットはキャッシュ済みなので軽い。
    public func groundingPreview(criteria: String) async -> AIAlbumGroundingPreview {
        let trimmed = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AIAlbumGroundingPreview() }
        let data = await suggestionData()
        let now = Date()
        var preview = AIAlbumGroundingPreview()

        // 人物（決定的接地: 太郎 → 山田太郎）。
        let grounded = PersonNameGrounder.groundedNames(in: trimmed, names: data.people)
        preview.chips += grounded.map { .init(kind: .person, text: $0) }

        // 場所（カタログ実在の地名が原文に含まれるか＝サニタイザの接地と同じ思想）。
        let placeHits = (data.catalog.places + data.catalog.countries)
            .filter { !$0.isEmpty && trimmed.contains($0) }
        preview.chips += placeHits.map { .init(kind: .place, text: $0) }

        // 視覚語（レキシコン: 海 → sea）。人名部分を除いた残りで抽出（「花子」の「花」誤爆防止）。
        let visualText = PersonNameGrounder.strippingNames(from: trimmed, matched: grounded)
        preview.chips += JapaneseVisualLexicon.groundedPairs(in: visualText)
            .map { .init(kind: .visual, text: "\($0.japanese) → \($0.english)") }

        // 日付（RelativeDateParser＝本番と同じ唯一の出典）。解決後の期間を表示する。
        if let range = RelativeDateParser.parse(trimmed, now: now) {
            let (start, end) = range.resolved(now: now)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "ja_JP")
            fmt.dateFormat = "yyyy/M/d"
            preview.chips.append(.init(kind: .date, text: "\(fmt.string(from: start))〜\(fmt.string(from: end))"))
        }

        // ハード条件のヒット件数（本番の即時プレビューと同じ spec 構築＋場所ヒントで評価）。
        var spec = AIAlbumInterpreter.previewInterpretation(criteria: trimmed, now: now,
                                                            namedPeople: data.people).spec
        if !placeHits.isEmpty {
            if spec.clauses.isEmpty {
                spec.clauses = [QueryClause([.place(placeHits)])]
            } else {
                spec.clauses = spec.clauses.map { QueryClause($0.conditions + [.place(placeHits)]) }
            }
        }
        if spec.hasHardConstraints {
            let peopleMap: [String: [String]]? = spec.hasPeopleConditions
                ? await aiService.peopleByRefKeyProvider?() : nil
            let lite = data.lite
            preview.hardHitCount = await Task.detached(priority: .userInitiated) {
                QueryEvaluator.hardFilter(lite, spec: spec, now: now, peopleByRefKey: peopleMap).count
            }.value
        }
        return preview
    }
}
