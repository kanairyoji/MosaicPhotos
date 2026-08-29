import FaceCore
import PerceptionCore
import Foundation
import MosaicSupport

/// AI アルバムの作成・再設定・削除・再評価をまとめた**薄いファサード**。
/// 状態（公開アルバム配列）はエンジンが持ち、本サービスは store を更新して最新の AI アルバム一覧を返す。
/// 実処理は関心ごとの協調オブジェクトへ委譲する：
/// - 解釈（LLM 解釈＋翻訳＋サニタイズ＋永続化）: `AIAlbumInterpreter`
/// - 検索（タグ一致＋CLIP 対比＋字句の RRF 融合）: `AIAlbumSearcher`
/// - クエリ埋め込み（肯定フレーズ選定＋除外語ベクトル）: `QueryEmbedder`（フル/増分で同一実装）
/// - 証拠ゲート＋LLM 審査（self-consistency 多数決）: `AIAlbumVerificationCoordinator`
///
/// 設計方針（根本見直し・2026-07）: **解釈は検索文の性質であり、ライブラリの性質ではない。**
/// - LLM（解釈・翻訳）は**作成/編集時に 1 回だけ**実行し、`AIAlbumInterpretationStore` に永続化する。
///   起動時・写真追加時に LLM は一切走らない（旧: カタログ署名変化で全キャッシュ破棄→毎起動 LLM×全アルバム
///   ＝実測 9.4s のメインハング）。
/// - 解釈に存在しない地名・人名が含まれてもよい。照合（QueryEvaluator）は部分一致なので、
///   該当写真が索引され次第、自動的に当たり始める（再解釈は不要）。
/// - 再評価はフル（全ベクトルをページ走査）と**増分**（新規埋め込み分だけ採点してプールへマージ）の
///   2 経路。日常は増分、ズレが開いたらアイドル時にフルで整合を回復する。
@MainActor
final class AIAlbumService {
    let store: AutoAlbumStore   // internal: 再評価（+Refresh）が同じ型の別ファイルにあるため
    private let searcher: AIAlbumSearcher
    /// 解釈のライフサイクル（LLM 解釈＋翻訳＋接地＋`AIAlbumInterpretationStore` への永続化）。
    let interpreter: AIAlbumInterpreter
    /// P2: 証拠ゲート＋LLM 審査（FM 無し端末では審査スキップ）。
    let verification: AIAlbumVerificationCoordinator
    /// クエリ埋め込み（フル評価と増分評価で**同じ規則**を型で担保する）。
    private let embedder: QueryEmbedder
    /// 英訳フレーズ＋除外語 → CLIP テキスト埋め込み（肯定＋除外群）のメモリキャッシュ
    /// （増分評価で毎回エンコードしない）。
    var queryVectorCache: [String: QueryEmbedder.QueryVectors] = [:]
    /// 顔スキャンの実測（refKey → 顔数）を返す seam。FaceStore は別コンテナ（PeopleEngine 側）の
    /// ため init 連鎖でなく Composition Root から `AutoAlbumEngine.setFaceCountsProvider` で結線する。
    /// 「人」系の除外があるアルバムの評価で、顔が実際に写っている写真をハード除外するのに使う。
    var faceCountsProvider: (@Sendable () async -> [String: Int])? {
        get { verification.faceCountsProvider }
        set { verification.faceCountsProvider = newValue }
    }

    /// 笑顔の実測（refKey → 笑顔の顔数・顔スキャン済みのみ）を返す seam（S10・ADR-103）。
    /// 「笑っている写真」条件の評価に使う。Composition Root から結線。
    var smileCountsProvider: (@Sendable () async -> [String: Int])?

    /// 属性条件（笑顔・美的）のシグナルを、必要なときだけ取得する（S10・ADR-103）。
    /// 「綺麗」のしきい値はベストショットフィルタ（ADR-78）と同じ分布適応＝定義を 1 つに保つ。
    /// internal: コンポーザの件数プレビュー（`AutoAlbumEngine.groundingPreview`）も同じシグナルで
    /// 数える（シグナル無しの hardFilter は属性条件が fail-closed になり「綺麗な写真→0 枚」と出る）。
    func querySignalsIfNeeded(for spec: QuerySpec) async -> QuerySignals {
        var signals = QuerySignals()
        if spec.needsSmileSignal {
            signals.smileCounts = await smileCountsProvider?() ?? [:]
        }
        if spec.needsAestheticSignal, let tagStore {
            let scores = await tagStore.allAesthetics()
            signals.aesthetics = scores
            signals.aestheticFloor = PhotoQuality.adaptiveThreshold(scores: Array(scores.values))
        }
        // 人数条件（S12）: humanCount 実測（タグ付けパスで全写真に付く・網羅率 約86%）。
        if spec.needsPeopleCountSignal, let tagStore {
            signals.humanCounts = await tagStore.allHumanCounts()
        }
        return signals
    }

    /// 顔クラスタの**現在の**人物名（refKey → 名前）を返す seam。人物条件（.people 等）は
    /// `EnrichedPhoto.people`（初回焼き込み・更新されない）でなく **live 照合**する（実障害:
    /// 後から命名した人物が検索に反映されない）。Composition Root から結線。
    var peopleByRefKeyProvider: (@Sendable () async -> [String: [String]])?

    /// 人物条件があるアルバムだけ live 人物名マップを取得する（無関係なアルバムでは取得しない）。
    func peopleMapIfNeeded(for spec: QuerySpec) async -> [String: [String]]? {
        guard spec.hasPeopleConditions, let peopleByRefKeyProvider else { return nil }
        return await peopleByRefKeyProvider()
    }

    /// 名前付き人物（顔クラスタ）のフルネーム一覧を返す seam（人物名検索の接地用）。
    /// 解釈器へ委譲。Composition Root が `AutoAlbumEngine.setNamedPeopleProvider` で結線する。
    var namedPeopleProvider: (@Sendable () async -> [String])? {
        get { interpreter.namedPeopleProvider }
        set { interpreter.namedPeopleProvider = newValue }
    }

    /// 語彙接地（ADR-101）: 索引に実在するタグ語彙と、語×語彙の意味的な近さ（CLIP）。
    /// 未結線・CLIP 未同梱なら接地は行わず、従来どおりの語のまま検索する。
    var conceptExpander: ConceptExpander? {
        get { interpreter.conceptExpander }
        set { interpreter.conceptExpander = newValue }
    }

    /// シーンタグ・キャプションのストア（検索の一次ランキングと LLM 審査の入力）。
    let tagStore: TagStore?

    init(store: AutoAlbumStore, tagStore: TagStore? = nil,
         understanding: QueryUnderstanding, textEmbedder: TextEmbedder?,
         translator: QueryTranslator? = nil) {
        self.tagStore = tagStore
        self.store = store
        self.interpreter = AIAlbumInterpreter(store: store, understanding: understanding,
                                              translator: translator)
        self.verification = AIAlbumVerificationCoordinator(tagStore: tagStore)
        // 語彙は自前の TagStore から取れるのでここで結線する（Composition Root は
        // 近さの計算（CLIP）だけを注入すればよい・ADR-101）。
        self.interpreter.tagVocabularyProvider = { [weak tagStore] in
            await tagStore?.tagVocabulary() ?? []
        }
        self.embedder = QueryEmbedder(textEmbedder: textEmbedder)
        self.searcher = AIAlbumSearcher(textEmbedder: textEmbedder)
    }

    // MARK: - テスト用アクセサ（解釈の保存状態を検査する）

    func saveInterpretationForTesting(_ value: SavedInterpretation, for id: String) {
        interpreter.save(value, for: id)
    }

    func savedInterpretationForTesting(_ id: String) -> SavedInterpretation? {
        interpreter.saved(for: id)
    }

    // MARK: - 夜間の本番化（FM 解釈＋LLM 審査つきフル評価）

    /// 夜間の本番化: プレビューのまま（pendingFinalization）のアルバムだけ FM 解釈＋フル評価
    /// （証拠ゲート・LLM 審査・Refine 込み）を行う。ゲートが閉じたら残りは次回夜間へ。
    func finalizePending(_ albums: [AutoAlbumInfo], now: Date = Date()) async -> [AutoAlbumInfo] {
        let pendingIDs = albums.filter { interpreter.saved(for: $0.id)?.pendingFinalization == true }.map(\.id)
        guard !pendingIDs.isEmpty else { return albums }
        guard !isEvaluating else {
            Diagnostics.mark("aialbum.finalize: skip — already evaluating")
            return albums
        }
        isEvaluating = true
        defer { isEvaluating = false }
        Diagnostics.mark("aialbum.finalize: \(pendingIDs.count) pending")
        var out = albums
        let all = await store.allEnrichedPhotosLite()
        let embedCount = await store.embeddedCount()
        // 開始時の世代を控える（この後の長い await 中に削除・編集され得る）。
        let startedGenerations = Dictionary(uniqueKeysWithValues:
            albums.map { ($0.id, generation(of: $0.id)) })
        // カタログはループ外で 1 回だけ構築（refresh と同じ・diagnostics-48）。
        let catalog = await Task.detached(priority: .utility) { AIAlbumCatalog.build(from: all) }.value
        for id in pendingIDs {
            if BackgroundYield.heavyShouldPause() { break }   // ロック解除等 → 残りは次回夜間へ
            guard let index = out.firstIndex(where: { $0.id == id }),
                  let criteria = out[index].criteria, !criteria.isEmpty else { continue }
            // interpretation() は pending の解釈をキャッシュ扱いしない＝ここで FM 解釈が走る。
            var saved = await interpreter.interpretation(id: id, criteria: criteria, now: now,
                                                         baseLite: all, prebuiltCatalog: catalog)
            var (members, pool) = await rankedSearch(all, saved: saved, now: now)
            members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
            members = await verification.verified(members, criteria: criteria)
            // Refine: 空振りなら LLM がプローブ語を生成して 1 回だけ再検索（作成時から夜間へ移動）。
            if members.isEmpty {
                let probes = await interpreter.expandProbes(criteria)
                if !probes.isEmpty {
                    var alt = saved
                    alt.spec = QuerySpecSanitizer.withIncludeTerms(saved.spec, terms: probes)
                    let retry = await rankedSearch(all, saved: alt, now: now)
                    members = await verification.verified(retry.members, criteria: criteria)
                    if !members.isEmpty { pool = retry.pool }
                    Diagnostics.mark("aialbum.refine: probes=\(probes.joined(separator: ",")) → \(members.count)")
                }
            }
            saved.scoredPool = pool
            saved.evaluatedEmbedCount = embedCount
            saved.lastEvaluatedAt = now
            // ⚠️ LLM 審査を挟むので待ち時間が長い。消された／編集されたアルバムは書き戻さない。
            guard await canCommit(id: id, criteria: criteria, generation: startedGenerations[id] ?? 0) else {
                Diagnostics.mark("aialbum.finalize: '\(criteria)' discarded (album deleted or edited)")
                continue
            }
            interpreter.save(saved, for: id)
            let info = AIAlbumSearcher.buildInfo(id: id, title: out[index].title,
                                                 interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members,
                                                 aesthetics: await coverAesthetics(members),
                                                 usage: await coverUsage(members))
            await store.upsert(albumInfo: info)
            out[index] = info
            Diagnostics.mark("aialbum.finalize: '\(criteria)' → members=\(members.count)")
        }
        return out
    }

    /// 作成/編集直後の**即時本番化**（ADR-110）: FM 解釈＋フル評価＋証拠ゲート＋LLM 審査を
    /// その場で行う。ユーザーの明示操作（作成/更新ボタン）なので夜間ゲートの対象外・utility 優先度。
    /// 「バレエ」のようなレキシコン外の語が翌朝まで条件化されない問題（diagnostics-49）を解消する。
    /// 語彙接地だけは**重心キャッシュ済みのときのみ**（コールド構築は数十分＝夜間の仕事）。
    /// 接地を見送った場合は pendingFinalization が残り、夜間の finalize が接地込みで仕上げる。
    func finalizeNow(id: String, baseLite: [EnrichedPhoto]? = nil) async -> [AutoAlbumInfo]? {
        guard let album = (await loadAll()).first(where: { $0.id == id }),
              let criteria = album.criteria, !criteria.isEmpty else { return nil }
        let startedGeneration = generation(of: id)
        let now = Date()
        let all: [EnrichedPhoto]
        if let baseLite { all = baseLite } else { all = await store.allEnrichedPhotosLite() }
        var saved = await interpreter.interpretation(id: id, criteria: criteria, now: now,
                                                     baseLite: all, groundingCachedOnly: true)
        var (members, pool) = await rankedSearch(all, saved: saved, now: now)
        members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
        members = await verification.verified(members, criteria: criteria)
        saved.scoredPool = pool
        saved.evaluatedEmbedCount = await store.embeddedCount()
        saved.lastEvaluatedAt = now
        // ⚠️ 長い await の後。消された／編集されたアルバムを書き戻さない。
        guard await canCommit(id: id, criteria: criteria, generation: startedGeneration) else {
            Diagnostics.mark("aialbum.finalizeNow: '\(criteria)' discarded (album deleted or edited)")
            return await loadAll()
        }
        interpreter.save(saved, for: id)
        let info = AIAlbumSearcher.buildInfo(id: id, title: album.title,
                                             interpretedTitle: saved.spec.title,
                                             criteria: criteria, members: members,
                                             aesthetics: await coverAesthetics(members),
                                             usage: await coverUsage(members))
        await store.upsert(albumInfo: info)
        Diagnostics.mark("aialbum.finalizeNow: '\(criteria)' → members=\(members.count) "
                         + "pendingGrounding=\(saved.pendingFinalization == true)")
        return await loadAll()
    }

    /// フル評価（refresh/finalize）の in-flight ガード。diagnostics-50 では drift フル再評価が
    /// 10 秒間に 2 本並走し（定期ティックと BG ルーチンが同時発火・評価済み枚数 0 の直後）、
    /// make の採点と競合して score が 79 秒（通常 0.4〜1.6 秒）に劣化した。同時実行は常に無駄
    /// （同じ結果を二度計算）なので 1 本に絞る。
    /// ⚠️ 実体はここ（extension は格納プロパティを持てない）。使うのは `+Refresh`。
    var isEvaluating = false

    // MARK: - 世代（削除・編集との競合を防ぐ）

    /// アルバムごとの世代。**削除・作成/再設定のたびに進む**。
    ///
    /// ⚠️ 本番化（`finalizeNow` / `finalizePending`）やフル再評価は、開始時にアルバムを取得した後、
    /// 解釈・検索・LLM 審査で**長く await する**。その間にユーザーが削除すると、最後の upsert が
    /// **消したはずのアルバムを復活**させる。編集された場合は、古い条件の結果が新しい内容を
    /// 上書きする（レビュー指摘）。保存の直前に「まだ存在し、条件と世代が開始時のまま」かを確かめる。
    private var albumGeneration: [String: Int] = [:]

    func generation(of id: String) -> Int { albumGeneration[id] ?? 0 }

    /// 世代を進める（進行中の評価結果を無効にする）。
    private func bumpGeneration(of id: String) {
        albumGeneration[id] = generation(of: id) &+ 1
    }

    /// 評価結果を保存してよいか。開始時の世代と条件が今も一致し、アルバムが現存すること。
    func canCommit(id: String, criteria: String, generation started: Int) async -> Bool {
        guard generation(of: id) == started else { return false }
        guard let current = (await loadAll()).first(where: { $0.id == id }) else { return false }
        return current.criteria == criteria
    }

    // テスト用アクセサ（世代と保存可否の検査）。
    func generationForTesting(_ id: String) -> Int { generation(of: id) }
    func canCommitForTesting(id: String, criteria: String, generation started: Int) async -> Bool {
        await canCommit(id: id, criteria: criteria, generation: started)
    }

    // MARK: - 作成 / 再設定 / 削除

    /// 作成/再設定（共通）。**0 件でも保存**する。戻り値: (結果, 更新後の AI アルバム一覧 or nil)。
    /// - Parameter baseLite: 呼び出し側（エンジン）が保持する構築済みライブラリスナップショット。
    ///   コンポーザーはチップ/接地プレビュー用に全メタ（数万件の SwiftData fetch＝make の最重量部）を
    ///   既に取得しているため、それを渡すと再フェッチを丸ごと省ける。プレビュー（ヒット件数）と
    ///   同じデータで検索するので表示との一貫性も保たれる。nil なら従来どおりフェッチ。
    func make(id: String, title: String, criteria: String,
              baseLite: [EnrichedPhoto]? = nil) async -> (result: AIAlbumResult, albums: [AutoAlbumInfo]?) {
        let trimmed = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.empty, nil) }

        let now = Date()
        let t0 = CFAbsoluteTimeGetCurrent()
        bumpGeneration(of: id)       // 進行中の本番化・再評価の結果を無効にする
        interpreter.remove(id: id)   // 再設定（検索文変更）は解釈からやり直す
        // 作成/編集は**即時プレビュー**（決定的レイヤーのみ・LLM なし＝1〜2 秒）。
        // FM 解釈＋LLM 審査つきの本番化は夜間（finalizePending・電源＋Wi-Fi＋ロック中）に行う。
        let namedPeople = await namedPeopleProvider?() ?? []
        var saved = AIAlbumInterpreter.previewInterpretation(criteria: trimmed, now: now,
                                                             namedPeople: namedPeople)
        let all: [EnrichedPhoto]
        if let baseLite { all = baseLite } else { all = await store.allEnrichedPhotosLite() }
        let tFetch = CFAbsoluteTimeGetCurrent()
        var (members, pool) = await rankedSearch(all, saved: saved, now: now)
        let tSearch = CFAbsoluteTimeGetCurrent()
        // 証拠ゲート（除外つきのみ）はプレビューでも適用（除外の精度は落とさない）。
        members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
        saved.scoredPool = pool
        saved.evaluatedEmbedCount = await store.embeddedCount()
        interpreter.save(saved, for: id)
        // 体感速度の実測用（診断ログ）: どのフェーズが支配的かを端末で切り分けられるようにする。
        Diagnostics.mark("aialbum.make: '\(trimmed)' all=\(all.count) members=\(members.count) "
            + "snapshot=\(baseLite != nil) fetch=\(Int((tFetch - t0) * 1000))ms "
            + "search=\(Int((tSearch - tFetch) * 1000))ms "
            + "total=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        let info = AIAlbumSearcher.buildInfo(id: id, title: title, interpretedTitle: saved.spec.title,
                                             criteria: trimmed, members: members,
                                             aesthetics: await coverAesthetics(members),
                                                 usage: await coverUsage(members))
        await store.upsert(albumInfo: info)
        return (.created(info), await loadAll())
    }

    /// CLIP テキストタワーの遅延ロードを前倒しで温める（コンポーザー表示時に呼ぶ）。
    /// 未ロードのまま「作成」を押すと初回ロード（Core ML コンパイル・数秒〜十数秒）が
    /// make の検索フェーズに乗ってしまう。捨てクエリを 1 回埋め込んでロードを済ませておく。
    func prewarmTextEmbedder() async {
        await embedder.textEmbedder?.prewarm()
    }

    func delete(id: String) async -> [AutoAlbumInfo] {
        bumpGeneration(of: id)   // 進行中の評価が後から復活させないように
        await store.deleteAlbum(id: id)
        interpreter.remove(id: id)
        return await loadAll()
    }

    // MARK: - Private

    /// 増分評価用のクエリ埋め込み（肯定＋除外群）。フレーズ選定・埋め込みの規則は
    /// `QueryEmbedder` に集約（フル評価＝searchWithPool と**同一実装**）で、ここはキャッシュだけ持つ。
    func queryVectors(for saved: SavedInterpretation) async -> QueryEmbedder.QueryVectors? {
        // 実効内容語（ADR-109・フル評価＝searchWithPool と同一規則）。
        let include = saved.spec.effectiveContentTerms.include
        let exclude = saved.spec.allContentTerms.exclude
        let phrase = QueryEmbedder.phrase(include: include, exclude: exclude,
                                          semanticText: saved.semanticText,
                                          preferIncludeTerms: saved.spec.hasGroundedHardTerms)
        guard !phrase.isEmpty else { return nil }
        let probes = saved.probes ?? []
        let cacheKey = "\(phrase)|\(probes.joined(separator: ","))|\(exclude.joined(separator: ","))"
        if let cached = queryVectorCache[cacheKey] { return cached }
        guard let result = await embedder.embed(phrase: phrase, probes: probes,
                                                excludeTerms: exclude) else { return nil }
        queryVectorCache[cacheKey] = result
        return result
    }

    /// 「人」系の除外があるアルバムなら顔の実測を取得する（無関係なアルバムでは取得しない）。
    /// メンバーの美的スコア（カバー選択の加点用・photo-info-expansion）。
    func coverAesthetics(_ members: [EnrichedPhoto]) async -> [String: Double] {
        await tagStore?.aesthetics(forRefKeys: members.map(\.id)) ?? [:]
    }

    /// 利用カウンタの照会（エンジンが UsageStore を結線する・カバー選択の加点用）。
    var usageCounts: (@Sendable ([String]) async -> [String: PhotoUsageCounts])?

    func coverUsage(_ members: [EnrichedPhoto]) async -> [String: PhotoUsageCounts] {
        await usageCounts?(members.map(\.id)) ?? [:]
    }

    func faceCountsIfNeeded(for spec: QuerySpec) async -> [String: Int]? {
        guard AIAlbumSearcher.hasPeopleExclusion(spec), let faceCountsProvider else { return nil }
        return await faceCountsProvider()
    }

    func rankedSearch(_ allLite: [EnrichedPhoto], saved: SavedInterpretation,
                              now: Date) async -> (members: [EnrichedPhoto], pool: [String: Float]) {
        // 意味検索の clipVector はストアからページ単位で読む（一度に全件を載せない）。
        // ⚠️ スコアリング（数万件×512 次元コサイン＋フィルタ）は CPU を食うので Task.detached で
        // オフメイン実行する（本サービスは @MainActor。直呼びだと ~1s 級のメイン占有になる）。
        let searcher = self.searcher
        let store = self.store
        let spec = saved.spec
        let semanticText = saved.semanticText
        let probes = saved.probes ?? []
        // ⚠️ 段ごとに測る（ADR-99）。実機 diagnostics-45 では前面で AI アルバム評価が走り、
        //    メインが 9.9 秒／10.6 秒ブロックした。採点自体は下の `Task.detached` でオフメインだが、
        //    その**手前**で 86k 件規模の台帳（タグ・OCR・顔数・人物名）を集めており、どこが
        //    支配的かログから読めない。推測で直さず内訳を出す（CLAUDE.md 性能原則 5）。
        let tFace = PerfTrace.nowNs()
        let faceCounts = await faceCountsIfNeeded(for: spec)
        PerfTrace.logSpan("aialbum.faceCounts", ms: PerfTrace.msSince(tFace))
        // 人物条件は焼き込みでなく live 人物名（PeopleEngine）で照合する（命名/統合の追従）。
        let tPeople = PerfTrace.nowNs()
        let peopleMap = await peopleMapIfNeeded(for: spec)
        PerfTrace.logSpan("aialbum.peopleMap", ms: PerfTrace.msSince(tPeople))
        // P1: タグ台帳（refKey → シーンタグ）。一次ランキングと離散除外に使う。
        let tTags = PerfTrace.nowNs()
        let tags = await tagStore?.allTags() ?? [:]
        PerfTrace.logSpan("aialbum.tagsLedger", ms: PerfTrace.msSince(tTags))
        // OCR 台帳（refKey → 写真内テキスト）。字句検索チャネルへ（photo-info-expansion）。
        let tOcr = PerfTrace.nowNs()
        let ocr = await tagStore?.allOcrTexts() ?? [:]
        PerfTrace.logSpan("aialbum.ocrLedger", ms: PerfTrace.msSince(tOcr))
        // 人物証拠（humanCount）は人系の除外があるときだけ読む（86k 件の台帳なので無駄に引かない）。
        let tHuman = PerfTrace.nowNs()
        let humanCounts = faceCounts == nil ? [:] : (await tagStore?.allHumanCounts() ?? [:])
        PerfTrace.logSpan("aialbum.humanCounts", ms: PerfTrace.msSince(tHuman))
        // 属性条件（笑顔・美的）のシグナル（S10・ADR-103・条件があるときだけ取得）。
        let querySignals = await querySignalsIfNeeded(for: spec)
        let tScore = PerfTrace.nowNs()
        defer { PerfTrace.logSpan("aialbum.score", ms: PerfTrace.msSince(tScore)) }
        return await Task.detached(priority: .utility) {
            let (members, pool) = await searcher.searchWithPool(
                baseLite: allLite, spec: spec, now: now, semanticText: semanticText,
                probes: probes, faceCounts: faceCounts, humanCounts: humanCounts,
                photoTags: tags, ocrTexts: ocr,
                peopleByRefKey: peopleMap, signals: querySignals,
                loadPage: { offset, limit in
                    await store.enrichmentVectorPage(offset: offset, limit: limit)
                })
            let sorted = members.sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            return (sorted, pool)
        }.value
    }

    private func loadAll() async -> [AutoAlbumInfo] {
        (await store.allAlbums())
            .filter { $0.strategyID == AIAlbumStrategy.strategyID }
            .sorted { $0.representativeDate > $1.representativeDate }
    }
}
