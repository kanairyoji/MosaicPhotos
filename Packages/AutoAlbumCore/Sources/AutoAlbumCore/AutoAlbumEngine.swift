import FaceCore
import PerceptionCore
import CoreLocation
import Foundation
import MosaicSupport
import Observation
import Photos
import PhotoSourceKit

/// 自動アルバム生成のオーケストレーション（@Observable ファサード）。
/// 公開状態（各アルバム配列・フラグ）を保持し、実処理は協調オブジェクトへ委譲する：
/// - エンリッチ＋時間＋場所生成: 本体（`generate`）
/// - AI アルバム / 認識タグ付け / insight: `AutoAlbumEngine+Recognition.swift`（→ `AIAlbumService` / `PhotoTagger`）
/// - フォルダ名アルバム: `PathAlbumGenerator`
///
/// 関心ごとにファイルを分割しているため、extension から参照する協調オブジェクト・状態は internal にしている。
@MainActor
@Observable
public final class AutoAlbumEngine {

    public private(set) var albums: [AutoAlbumInfo] = []
    /// フォルダ名（Dropbox パス）から推測したアルバム（時間＋場所とは別セクション）。
    public private(set) var pathAlbums: [AutoAlbumInfo] = []
    /// 自然文から作る AI アルバム（ユーザー作成・保存）。
    public internal(set) var aiAlbums: [AutoAlbumInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isGenerating = false {
        didSet { BackgroundActivityMonitor.shared.generatingTimePlace = isGenerating }
    }
    /// フォルダ名アルバムだけの軽量再生成中フラグ（地名解決を伴わないので速い）。
    public private(set) var isGeneratingPath = false {
        didSet { BackgroundActivityMonitor.shared.generatingFolder = isGeneratingPath }
    }
    /// AI アルバムを作成/更新中のフラグ（UI のスピナー用）。コンポーザーは即 dismiss し、
    /// 実処理はバックグラウンドで進むため、AI アルバムのセクションヘッダーでこの間だけ回す。
    public internal(set) var isMakingAIAlbum = false
    /// Vision/CLIP タグ付けの実行中フラグ（UI のスピナー用）。
    public internal(set) var isTagging = false {
        didSet {
            BackgroundActivityMonitor.shared.isEmbedding = isTagging
            if !isTagging { BackgroundActivityMonitor.shared.embedRemaining = 0 }
        }
    }
    public internal(set) var status: String = ""

    @ObservationIgnored static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Engine")
    @ObservationIgnored let store: AutoAlbumStore
    @ObservationIgnored private let enricher = PhotoEnricher()
    @ObservationIgnored private let strategies: [AlbumStrategy] = [TimePlaceStrategy()]
    @ObservationIgnored private let cloudProvider: CloudPhotoProvider?
    @ObservationIgnored private let backupLink: BackupLinkProvider?
    @ObservationIgnored private let peopleProvider: PeopleProvider?
    @ObservationIgnored let aiService: AIAlbumService
    @ObservationIgnored private let pathGenerator: PathAlbumGenerator
    @ObservationIgnored let tagger: PhotoTagger
    @ObservationIgnored private var observer: PhotoLibraryObserver?
    @ObservationIgnored private var libraryDirty = false
    /// 背景タグ付け/埋め込み/キャプションのタスク（`scheduleBackgroundFill`）。
    /// フォアグラウンド復帰で明示キャンセルするために保持する（ADR-79）。
    @ObservationIgnored var backgroundFillTask: Task<Void, Never>?
    /// `scheduleBackgroundFill` の世代。`restartBackgroundFill` で明け渡すたびに進み、
    /// 各タスクの末尾処理は「自分の世代のときだけ」フラグ／ハンドルを片付ける（ADR-95）。
    @ObservationIgnored var fillGeneration = 0
    /// 表示ラベラの事前ウォーム（CLIP テキストタワー＋約300語）。復帰時に止める（ADR-80）。
    @ObservationIgnored var prewarmTask: Task<Void, Never>?
    /// 重い保守処理（generate）の世代。`stopBackgroundWork()` で進み、実行中の generate は
    /// ステップ境界で世代のズレを見て自ら降りる（ADR-79 追記）。
    ///
    /// `generate` は**呼び出し側のタスク上で実行される**（前面の定期ループ＝HomeView からも呼ばれる）。
    /// そのため `Task.isCancelled` だけでは止められない（そのループ自体を殺すわけにいかない）。
    /// 世代番号なら「誰が起動した generate でも、停止要求より前のものは降りる」を一様に表現できる。
    @ObservationIgnored private var workEpoch = 0

    /// 現在の世代を採番して返す（重い処理の開始時に捕まえる）。
    func beginWorkEpoch() -> Int { workEpoch }

    /// 停止要求が出たか（`epoch` は開始時に `beginWorkEpoch()` で得た値）。
    func isAborted(_ epoch: Int) -> Bool { Task.isCancelled || workEpoch != epoch }

    /// 実行中の重い保守処理に「降りろ」と伝える（次のステップ境界で降りる）。
    func requestAbortHeavyWork() { workEpoch &+= 1 }

    /// 地名補正を最後に実行したときの署名（写真件数＋Apple 補正の世代）。
    /// 変化が無ければ 86k 件の読み出しごとスキップする（ADR-79 追記）。
    @ObservationIgnored private var lastPlaceRefineSignature = ""
    /// 前回 generate 時のクラウド署名。**UserDefaults に永続**する（Fix A）。
    /// 以前はプロセス起動ごとに 0 に戻るため、jetsam 再起動のたびに「署名が変わった」と誤判定して
    /// 86k 件の重い generate（実測 ~800MB）を再実行 → また jetsam、という悪循環になっていた。
    @ObservationIgnored private var lastCloudSignature: Int {
        get { UserDefaults.standard.integer(forKey: Self.lastCloudSignatureKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCloudSignatureKey) }
    }
    private static let lastCloudSignatureKey = "autoalbum.lastCloudSignature"
    /// ユーザーが写真を能動操作中か（スクラブ等）。背景 CLIP 埋め込みを一時停止するために使う（G）。
    /// Recognition extension から参照するため internal。
    @ObservationIgnored var isInteracting = false
    /// AI アルバム作成のサジェスト/接地プレビュー用のスナップショット（Suggestions extension が管理・
    /// 5 分で失効）。コンポーザーを開いている間のタイプごとの 85k 再フェッチを避ける。
    @ObservationIgnored var suggestionSnapshot: AIAlbumSuggestionSnapshot?
    /// T5: AI アルバム再評価の時間スロットル用（Recognition extension が参照）。
    @ObservationIgnored var lastAIRefreshAt = Date.distantPast
    /// Phase 2: スロットル中に蓄積する「新規に埋め込まれた refKey」（増分再評価の入力）。
    @ObservationIgnored var pendingNewEmbeds: [String] = []

    @ObservationIgnored let labelProvider: LabelProvider?
    /// シーンタグ・キャプションのストア／トリクル付与（TagsV1 別コンテナ）。
    @ObservationIgnored let tagStore: TagStore
    @ObservationIgnored let usageStore: UsageStore
    @ObservationIgnored let tagTagger: TagTagger

    /// ⚠️ 直 init は「呼び出しスレッドで AutoAlbumStore（@ModelActor）を作る」＝ MainActor から
    /// 呼ぶと全 SwiftData 処理（85k fetch/prune/upsert）がメインスレッドで走る（実測 14.5s ハング）。
    /// **本番は `makeWithOffMainStore` を使う**こと（直 init はテスト用）。
    public convenience init(cloudProvider: CloudPhotoProvider? = nil, backupLink: BackupLinkProvider? = nil,
                            peopleProvider: PeopleProvider? = nil, queryUnderstanding: QueryUnderstanding? = nil,
                            perception: PhotoPerceptionProvider? = nil, textEmbedder: TextEmbedder? = nil,
                            translator: QueryTranslator? = nil, labelProvider: LabelProvider? = nil) {
        self.init(cloudProvider: cloudProvider, backupLink: backupLink, peopleProvider: peopleProvider,
                  queryUnderstanding: queryUnderstanding, perception: perception, textEmbedder: textEmbedder,
                  translator: translator, labelProvider: labelProvider, store: nil)
    }

    /// 本番用ファクトリ。@ModelActor（AutoAlbumStore）を**オフメインで生成**してから組み立てる。
    public static func makeWithOffMainStore(
        cloudProvider: CloudPhotoProvider? = nil, backupLink: BackupLinkProvider? = nil,
        peopleProvider: PeopleProvider? = nil, queryUnderstanding: QueryUnderstanding? = nil,
        perception: PhotoPerceptionProvider? = nil, textEmbedder: TextEmbedder? = nil,
        translator: QueryTranslator? = nil, labelProvider: LabelProvider? = nil,
        tagProvider: TagPerceptionProvider? = nil
    ) async -> AutoAlbumEngine {
        let store = await Task.detached(priority: .userInitiated) { AutoAlbumStore() }.value
        let tagStore = await Task.detached(priority: .userInitiated) { TagStore() }.value
        let usageStore = await Task.detached(priority: .userInitiated) { UsageStore() }.value
        return AutoAlbumEngine(cloudProvider: cloudProvider, backupLink: backupLink,
                               peopleProvider: peopleProvider, queryUnderstanding: queryUnderstanding,
                               perception: perception, textEmbedder: textEmbedder,
                               translator: translator, labelProvider: labelProvider, store: store,
                               tagStore: tagStore, tagProvider: tagProvider, usageStore: usageStore)
    }

    init(cloudProvider: CloudPhotoProvider? = nil, backupLink: BackupLinkProvider? = nil,
         peopleProvider: PeopleProvider? = nil, queryUnderstanding: QueryUnderstanding? = nil,
         perception: PhotoPerceptionProvider? = nil, textEmbedder: TextEmbedder? = nil,
         translator: QueryTranslator? = nil, labelProvider: LabelProvider? = nil,
         store: AutoAlbumStore? = nil, tagStore: TagStore? = nil,
         tagProvider: TagPerceptionProvider? = nil, usageStore: UsageStore? = nil) {
        let store = store ?? AutoAlbumStore()
        let tagStore = tagStore ?? TagStore()
        self.tagStore = tagStore
        self.usageStore = usageStore ?? UsageStore()
        self.tagTagger = TagTagger(store: tagStore, provider: tagProvider)
        self.store = store
        self.cloudProvider = cloudProvider
        self.backupLink = backupLink
        self.peopleProvider = peopleProvider
        self.labelProvider = labelProvider
        self.aiService = AIAlbumService(store: store, tagStore: tagStore,
                                        understanding: queryUnderstanding ?? makeDefaultQueryUnderstanding(),
                                        textEmbedder: textEmbedder,
                                        translator: translator)
        // カバー選定の利用シグナル（共有/閲覧）: AIAlbumService から UsageStore を引けるようにする。
        aiService.usageCounts = { [usageStore = self.usageStore] keys in
            await usageStore.counts(forRefKeys: keys)
        }
        self.pathGenerator = PathAlbumGenerator(store: store, cloudProvider: cloudProvider)
        self.tagger = PhotoTagger(store: store, perception: perception)
    }

    public func enrichmentCount() async -> Int { await store.enrichmentCount() }

    /// 未 CLIP 埋め込みの写真数（3-b: バックアップを AI 残作業と同一窓で走らせないための判定用）。
    public func pendingEmbedCount() async -> Int { await store.unembeddedCount() }

    /// 顔スキャンの実測（refKey → 顔数）を AI アルバム評価に結線する（「人が写っていない」等の
    /// 除外判定に使う）。FaceStore は別コンテナ（PeopleEngine 側）のため、init 連鎖ではなく
    /// Composition Root（アプリの AutoAlbumAdapters）から注入する。
    public func setFaceCountsProvider(_ provider: @escaping @Sendable () async -> [String: Int]) {
        aiService.faceCountsProvider = provider
    }

    /// 名前付き人物（顔クラスタ）のフルネーム一覧を AI アルバムの人物名検索へ結線する
    /// （「太郎と花子」→「木村太郎」「木村花子」等の接地に使う）。Composition Root から注入。
    public func setNamedPeopleProvider(_ provider: @escaping @Sendable () async -> [String]) {
        aiService.namedPeopleProvider = provider
    }

    /// 語×語彙の意味的な近さを結線する（ADR-101）。これにより「風景」のような索引に実在しない語が、
    /// 台帳のタグ（mountain / beach …）へ**語彙の側から**展開される。個別の対応表は持たない。
    /// 未注入なら接地は行わない（従来どおりの語のまま検索する）。
    public func setConceptExpander(_ expander: ConceptExpander) {
        aiService.conceptExpander = expander
    }

    /// 笑顔の実測（refKey → 笑顔の顔数）を AI アルバムの `.smiling` 条件へ結線する（S10・ADR-103）。
    public func setSmileCountsProvider(_ provider: @escaping @Sendable () async -> [String: Int]) {
        aiService.smileCountsProvider = provider
    }

    /// タグ重心の供給（`CLIPConceptExpander` の材料）。タグ台帳と埋め込みは本エンジンが持つので、
    /// Composition Root は「重心を使う実装」を作るだけでよい。
    /// 新規の推論は無く、保存済み `PhotoEmbedding` を 1 回舐めて平均するだけ（ADR-101）。
    public func tagCentroids(for vocabulary: [String]) async -> [String: [Float]] {
        let tags = await tagStore.allTags()
        let store = self.store
        return await TagCentroids.build(vocabulary: vocabulary, tagsByRefKey: tags,
                                        loadPage: { offset, limit in
            await store.enrichmentVectorPage(offset: offset, limit: limit)
        })
    }

    /// 顔クラスタの**現在の**人物名（refKey → 名前）を AI アルバムの人物条件評価へ結線する。
    /// 人物名はリネーム/統合/クラスタ成長で変わるため、焼き込み（EnrichedPhoto.people）でなく
    /// **検索時に live 照合**する（実障害: 後から命名した人物が検索に反映されない）。
    public func setPeopleByRefKeyProvider(_ provider: @escaping @Sendable () async -> [String: [String]]) {
        aiService.peopleByRefKeyProvider = provider
    }

    /// お気に入り（Favorite）写真の refKey 集合を供給する seam。解析順の優先付け
    /// （お気に入りを先に埋め込む）に使う。Composition Root（アプリ）が PHAsset の
    /// favorite==YES を注入する。
    @ObservationIgnored var favoriteRefKeysProvider: (@Sendable () async -> Set<String>)?
    /// お気に入り集合のキャッシュ（解析順の優先付けに使う・scheduleBackgroundFill で更新）。
    @ObservationIgnored var favoritesCache: Set<String> = []

    public func setFavoriteRefKeysProvider(_ provider: @escaping @Sendable () async -> Set<String>) {
        favoriteRefKeysProvider = provider
    }

    /// お気に入り集合を取り込み直してキャッシュする。
    func refreshFavoritesCache() async {
        if let p = favoriteRefKeysProvider { favoritesCache = await p() }
    }

    /// ユーザーが写真を能動操作中か（スクラブ等）を設定する。true の間は背景 CLIP 埋め込みを譲る（G）。
    public func setInteracting(_ value: Bool) { isInteracting = value }

    // MARK: - Path albums

    /// フォルダ名アルバムだけを軽量・バックグラウンドで再生成する（地名解決なし）。
    public func generatePathAlbums() async {
        guard !isGeneratingPath else { return }
        isGeneratingPath = true
        defer { isGeneratingPath = false }
        pathAlbums = await pathGenerator.generateFast()
        if !isGenerating { status = "\(albums.count) trips · \(pathAlbums.count) folders" }
    }

    // MARK: - Lifecycle

    /// 自動アルバム生成ロジックのバージョン。命名・グルーピングを変えたら上げる。
    /// 保存値と異なると起動時に1回だけ自動再生成し、既存アルバムへ改善を反映する。
    /// v4: オフライン地名解決（GeoNames）＋未測位写真を旅行から除外＋日英の地名へ。
    ///     既存の「Trip」固定アルバムを地名付きへ作り直す。
    private static let generationVersion = 4

    /// タグ付け（Vision/CLIP 知覚）ロジックのバージョン。抽出の改善時に上げると、起動時に1回だけ
    /// 全ローカル写真の sceneTagged をリセットして付け直す（メタデータ・地名は保持）。
    static let perceptionVersion = 8   // v8: CLIP を INT8 量子化（重み半減・精度ほぼ不変）→全再埋め込み（ADR-31）

    public func loadOrGenerate() async {
        ensureObserver()
        if albums.isEmpty && pathAlbums.isEmpty && aiAlbums.isEmpty {
            let all = await store.allAlbums()
            albums = all.filter { $0.strategyID == TimePlaceStrategy.strategyID }
            pathAlbums = all.filter { $0.strategyID == PathAlbumStrategy.strategyID }
            aiAlbums = all.filter { $0.strategyID == AIAlbumStrategy.strategyID }
        }
        isLoaded = true

        // 実機の起動時メモリ/CPU スパイク回避：保存済みアルバムの表示は即時に行い、重い再生成・AI 再評価・
        // 背景タグ付け（67k の clipVector ロードや CLIP モデル初期化）は、グリッドや Dropbox キャッシュの
        // 初期読み込みと**同時に**走らないよう少し遅らせる（同時スパイクが jetsam/watchdog を誘発するため）。
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { return }

        let storedVersion = UserDefaults.standard.integer(forKey: AutoAlbumSettingsKeys.generationVersion)
        Self.log.info("loadOrGenerate: albums=\(albums.count) storedVersion=\(storedVersion) target=\(Self.generationVersion)")
        if albums.isEmpty || storedVersion != Self.generationVersion {
            await generate()
        }
        // 知覚ロジックを更新したら、既存の sceneTagged を1回だけリセットして付け直す。
        let storedPerception = UserDefaults.standard.integer(forKey: AutoAlbumSettingsKeys.perceptionVersion)
        if storedPerception != Self.perceptionVersion {
            let reset = await store.resetSceneTagged()
            UserDefaults.standard.set(Self.perceptionVersion, forKey: AutoAlbumSettingsKeys.perceptionVersion)
            Self.log.info("loadOrGenerate: perception v\(storedPerception)→\(Self.perceptionVersion), reset \(reset) photos for re-tagging")
        }
        // 起動時の AI アルバム再評価は行わない（保存済みメンバーをそのまま表示）。
        // 解釈は永続化済みで、追いつきはドリフト検知（refreshIfNeeded・アイドル時）と
        // 埋め込み進行の増分評価（refreshAIAlbumsThrottled）が担う。
        // フォルダ名アルバムは現在の Dropbox 一覧から作り直して自己修復する。
        // ⚠️ `generate()` はエンリッチ台帳（過去のアカウント/同期時点のクラウドパスが残り得る）から
        //    パスアルバムを作るため、Dropbox のアカウントやフォルダ構成が変わると保存済みメンバーが
        //    現在の `dropboxStore.items` と 1 件も一致せず、開いてもサムネイルが 0 件になる（実障害）。
        //    `generatePathAlbums()`（=generateFast）は cloudProvider の現在の一覧を出典にするので、
        //    存在しないパスのアルバムは消え、現存フォルダのアルバムは正しいパスで作り直される。
        if UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.pathAlbumsEnabled) {
            await generatePathAlbums()
        }

        Self.log.info("loadOrGenerate: scheduling background tagging")
        scheduleBackgroundFill()
    }

    /// バックグラウンド自動生成が有効で、ローカル/クラウドに変化があれば再生成する（定期ティック用）。
    public func refreshIfNeeded() async {
        guard isLoaded, !isGenerating else { return }
        // 重い処理の共通方針: 電源接続＋低電力 OFF＋一定時間アイドルのときだけ動かす
        // （人が使っている気配がある間は背景でも動かさない・次のティックで再判定）。
        guard BackgroundYield.heavyWorkAllowed else { return }

        // 本番化・ドリフト再評価は**一枚岩**（FM 解釈＋フル検索＋重心構築＝始まると譲れない）
        // なので、非アクティブ限定の厳格ゲートを通す。前面アイドル（控えめ OFF＋20 秒放置）で
        // 動かすと、ユーザーが戻ってきた後も数分〜数十分 ANE/CPU を占有して操作が毎回固まる
        // （diagnostics-46・ADR-107）。トリクル系（埋め込み等）は従来どおり前面アイドルでも動く。
        if BackgroundYield.monolithicHeavyWorkAllowed {
            // プレビューのままの AI アルバムを本番化（FM 解釈＋LLM 審査つきフル評価）。
            // 作成時は決定的プレビューだけ出す方針のため、本番化はこのゲート内（夜間）で行う。
            aiAlbums = await aiService.finalizePending(aiAlbums)

            // AI アルバムのドリフト検知（自動生成トグルとは独立）：埋め込みの進行に対して
            // 評価済み時点が大きく遅れていたらフル再評価で整合を回復する（LLM は走らない）。
            if let refreshed = await aiService.refreshIfDrifted(aiAlbums) {
                aiAlbums = refreshed
            }
        }

        // 地名の高精度化（Apple・背景）: 写真のあるグリッドセルを枚数の多い順に CLGeocoder で高精度化し、
        // 変わった地名を台帳へ伝播して trips を作り直す。成功のみ永続・失敗はリトライ・既補正はスキップ＝収束後は無コスト。
        await refinePlaceNames(shouldContinue: { await MainActor.run { BackgroundYield.heavyWorkAllowed } })

        guard UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.backgroundEnabled) else { return }
        // 自動生成も一枚岩（85k 件の SwiftData 処理・isGeneratingAlbums で他を全部止める）＝
        // 前面では動かさない（ADR-107）。
        guard BackgroundYield.monolithicHeavyWorkAllowed else { return }
        let cloudChanged = await cloudSignatureChanged()
        guard libraryDirty || cloudChanged else { return }
        libraryDirty = false
        await generate()
    }

    /// 台帳の座標付き写真から「使用中グリッドセル」の重心座標を枚数の多い順に返す（Apple 補正の対象）。
    /// 旧実装のトリップ代表座標（メンバー平均）は複数都市の旅行で無意味な地点になるため廃止した。
    private func placeRefinementTargets() async -> (photos: [EnrichedPhoto], cells: [CLLocationCoordinate2D]) {
        let photos = await store.allEnrichedPhotosLite()
        let cells = await Task.detached(priority: .utility) {
            PlaceRefinement.cellCentroids(photos: photos)
        }.value
        return (photos, cells)
    }

    /// 写真のあるグリッドセルを Apple（CLGeocoder）で高精度化し、**変わった地名を台帳へ伝播**して
    /// trips を作り直す。オフライン都市 DB の「最寄り大都市スナップ」を正確な市区町村へ置き換える。
    /// - セルは枚数の多い順・1 晩 300 件まで（数晩で全セルに収束。以後は refined スキップ＝無コスト）。
    /// - 伝播は毎回行う（補正済みキャッシュと台帳の差分を取るだけ＝安価）。過去の補正が中断などで
    ///   台帳へ届いていなくても自己修復する。台帳の placeName は trips・AI 検索（LexicalSearch）の出典。
    /// 戻り値＝新たに高精度化した地点数。`shouldContinue` は heavy ゲート（背景）や `{ true }`（手動）。
    @discardableResult
    private func refinePlaceNames(force: Bool = false,
                                  shouldContinue: @escaping @Sendable () async -> Bool) async -> Int {
        // ⚠️ 空振りの早期リターン（ADR-79 追記）。この関数は台帳 86k 件を丸ごと読む（セル抽出と
        // 伝播の差分計算に全件が要る）。定期ティックのたびに実行すると**毎回 10 秒級のスパイク**に
        // なる（実機ログ diagnostics-31: 復帰直前に `hang main=10581ms`）。
        // 「写真の件数」と「Apple 補正の世代」が前回から変わっていなければ、結果は必ず同じなので読まない。
        let signature = "\(await store.enrichmentCount())-\(await PlaceNameResolver.shared.refinementGeneration)"
        if !force, signature == lastPlaceRefineSignature { return 0 }

        let (photos, cells) = await placeRefinementTargets()
        guard !cells.isEmpty else { lastPlaceRefineSignature = signature; return 0 }
        // オフライン解決ロジックの版上げでキャッシュが破棄されたセルを先に埋め直す（即時・通信不要）。
        for cell in cells { _ = await PlaceNameResolver.shared.cityName(for: cell) }
        let refined = await PlaceNameResolver.shared.refineWithAppleGeocoder(
            coordinates: cells, shouldContinue: shouldContinue)
        // 伝播: resolver キャッシュの現在値で台帳の placeName/country を引き直す（差分のみ更新）。
        let cache = await PlaceNameResolver.shared.cachedComponentsSnapshot()
        let prefix = PlaceNameResolver.keyPrefix
        let changes = await Task.detached(priority: .utility) {
            PlaceRefinement.ledgerChanges(photos: photos, cache: cache, keyPrefix: prefix)
        }.value
        if !changes.isEmpty {
            await store.updatePlaces(changes)
            await PlaceNameResolver.shared.persist()
            Self.log.info("place refine: \(refined) cells upgraded via CLGeocoder, \(changes.count) photos renamed — regenerating trips")
            await generate()
        }
        // 補正で世代が進んだ場合に備え、**実行後の**署名を記録する（次ティックは空振りで即帰る）。
        lastPlaceRefineSignature =
            "\(await store.enrichmentCount())-\(await PlaceNameResolver.shared.refinementGeneration)"
        return refined
    }

    /// デバッグ: Apple(CLGeocoder)の地名補正を**今すぐ**実行する（heavy ゲート無視）。動作確認用に、
    /// 最多枚数セル 1 点の直接ジオコーディング結果（サンプル）と高精度化した地点数を人間可読で返す。
    public func refinePlaceNamesNow() async -> String {
        let (_, cells) = await placeRefinementTargets()
        guard let first = cells.first else {
            return "位置情報つきの写真がありません"
        }
        let sample = await PlaceNameResolver.shared.debugGeocode(first) ?? "（取得できず＝通信不可／圏外）"
        // デバッグ操作は空振り早期リターンを無視して必ず実行する（動作確認が目的のため）。
        let refined = await refinePlaceNames(force: true, shouldContinue: { true })
        return "Apple の地名 取得成功 — 例: \(sample) ／ 高精度化 \(refined) 地点"
    }

    public func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false; isLoaded = true }

        Self.log.info("generate: begin")
        let t0 = Date()
        let epoch = beginWorkEpoch()
        _ = await ensurePhotoAuthorization()
        let existing = await store.enrichedRefKeys()
        let backupMap = await backupLink?.localToCloudPath() ?? [:]
        let peopleMap = await peopleProvider?.peopleByLocalIdentifier() ?? [:]

        // 1. ローカル：新規をエンリッチ（linkKey はバックアップ対応から付与・人物は顔認識から付与）。
        let localResult = await enricher.enrichLocal(existing: existing, peopleMap: peopleMap)
        let localNew = localResult.new.map { photo in
            photo.withLinkKey(photo.ref?.localIdentifier.flatMap { backupMap[$0] })
        }
        // メタデータは即座に保存（高速）。Vision タグは別途バックグラウンドで増分付与する。
        await store.upsert(localNew)
        Self.log.info("generate: local enriched — \(localNew.count) new, \(localResult.current.count) current")
        var currentRefKeys = localResult.current

        // 2. クラウド：設定 ON かつ provider があればエンリッチ。
        //    67k 件のループ（refKey 生成・Set 操作・geocode）は Task.detached でオフメインに
        //    （エンジンは @MainActor のため、直呼びだとこのループがメインスレッドを塞ぐ）。
        if includeCloud, let cloudProvider {
            Diagnostics.mark("generate.step2: cloud metas…")
            let metas = await cloudProvider.cloudPhotos()
            Diagnostics.mark("generate.step2: metas=\(metas.count) → enrich…")
            let enricher = self.enricher
            let (sig, cloudResult) = await Task.detached(priority: .utility) {
                (Self.signature(of: metas), await enricher.enrichCloud(metas: metas, existing: existing))
            }.value
            lastCloudSignature = sig
            await store.upsert(cloudResult.new)
            currentRefKeys.formUnion(cloudResult.current)
        }

        // ADR-79: ステップ境界で中断を確認する。generate は 18 秒超・ピーク 550〜880MB の
        // 一枚岩で、フォアグラウンド復帰後も完走して固まりの原因になっていた。ここまでの
        // upsert は台帳へ確定済み・処理は差分ベースなので、途中で降りても次回続きから進む。
        if isAborted(epoch) { Diagnostics.mark("generate: aborted (after enrich)"); return }

        // 3. 現存しない写真の付加情報を削除。既存ローカルの linkKey をバックアップ最新で更新。
        Diagnostics.mark("generate.step3: prune…")
        await store.prune(keeping: currentRefKeys)
        await store.refreshLocalLinkKeys(backupMap)
        if isAborted(epoch) { Diagnostics.mark("generate: aborted (after prune)"); return }

        // 4〜6. 重複排除・旅行抽出・フォルダ名アルバムは 85k 件規模の純計算。
        //    まとめて Task.detached（オフメイン）で行い、メインは結果の代入だけにする
        //    （従来はエンジン＝@MainActor 上で実行され、実測で main を最大 12 秒塞いでいた）。
        //    生成は意味検索を伴わないため clipVector を載せない軽量版を使う（実機メモリ削減）。
        Diagnostics.mark("generate.step4: detached fetch+compute…")
        let excludeAlbumed = UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.excludeAlbumed)
        let albumed = excludeAlbumed ? await PhotoEnricher.userAlbumedIdentifiers() : []
        let params = AlbumGenParams.current
        let strategies = self.strategies
        let store = self.store

        // 3-a: 以前は `photos`（86k の EnrichedPhoto 配列）を**メインへ返して .count だけ**に使い、
        // 86k×文字列複数の配列をメイン側に握り続けていた。返すのは件数だけにして常駐ピークを下げる。
        // ADR-79: 台帳の**取得もこの detached 内**で行う。以前は `allEnrichedPhotosLite()` の結果を
        // 一旦 @MainActor のここで受けており、86k 件の受け渡しでメインが実測 ~10 秒止まっていた
        // （diagnostics-30 の `hang main=10342ms` が generate.step4 と一致）。メインは件数と
        // 生成済みアルバム（数百件）だけを受け取る。
        let (photoCount, infos, pathInfos) = await Task.detached(priority: .utility)
        { () -> (Int, [AutoAlbumInfo], [AutoAlbumInfo]) in
            let allEnriched = await store.allEnrichedPhotosLite()
            Diagnostics.mark("generate.step4: lite=\(allEnriched.count) → compute…")
            var photos = dedupByLinkKey(allEnriched)
            if excludeAlbumed {
                photos = photos.filter { ref in
                    guard let localId = PhotoRef.decode(ref.id)?.localIdentifier else { return true }
                    return !albumed.contains(localId)
                }
            }

            // 各戦略で時間＋場所アルバム化（地名が空なら代表座標を逆ジオコーディングして補完）。
            var infos: [AutoAlbumInfo] = []
            for strategy in strategies {
                for rawDraft in strategy.makeAlbums(from: photos, params: params) {
                    let draft = await Self.resolvePlaceIfNeeded(rawDraft)
                    infos.append(AutoAlbumInfo(
                        id: AutoAlbumComposer.stableID(draft), strategyID: draft.strategyID,
                        title: AutoAlbumComposer.title(draft), placeName: draft.placeName, places: draft.places,
                        country: draft.country, people: draft.people,
                        startDate: draft.startDate, endDate: draft.endDate, coverRef: draft.coverRef,
                        memberRefs: draft.memberRefs, photoCount: draft.photoCount,
                        representativeDate: draft.representativeDate,
                        latitude: draft.latitude, longitude: draft.longitude))
                }
            }
            infos.sort { $0.representativeDate > $1.representativeDate }

            // フォルダ名アルバム（任意・既定 OFF）。
            let pathInfos = PathAlbumGenerator.computeFromEnriched(allEnriched)
            return (photos.count, infos, pathInfos)
        }.value

        Diagnostics.mark("generate.step5: compute done → save…")
        // 計算結果の保存直前でも中断を確認する（保存は albums 置換＝一括なので途中止めはしない）。
        if isAborted(epoch) { Diagnostics.mark("generate: aborted (before save)"); return }
        await PlaceNameResolver.shared.persist()
        await store.replaceAlbums(forStrategy: TimePlaceStrategy.strategyID, with: infos)
        await store.replaceAlbums(forStrategy: PathAlbumStrategy.strategyID, with: pathInfos)
        albums = infos
        pathAlbums = pathInfos
        UserDefaults.standard.set(Self.generationVersion, forKey: AutoAlbumSettingsKeys.generationVersion)
        status = "\(infos.count) trips · \(pathInfos.count) folders · \(photoCount) photos"
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        Self.log.info("generate: end in \(secs)s — \(infos.count) trips, \(pathInfos.count) folders, \(photoCount) photos")
    }

    public func clear() async {
        await store.clearAll()
        albums = []
        pathAlbums = []
        aiAlbums = []
        aiService.clearCache()
        status = ""
        lastCloudSignature = 0
    }

    // MARK: - Private

    /// 地名が空のアルバムについて、代表座標から場所名を解決して draft に補う。
    /// `nonisolated static`：生成のオフメイン計算（Task.detached）から呼ぶ（中身は actor 呼び出しのみ）。
    nonisolated private static func resolvePlaceIfNeeded(_ draft: GeneratedAlbumDraft) async -> GeneratedAlbumDraft {
        guard draft.places.isEmpty, let lat = draft.latitude, let lon = draft.longitude else { return draft }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard let name = await PlaceNameResolver.shared.cityName(for: coordinate) else { return draft }
        var country = draft.country
        if country == nil { country = await PlaceNameResolver.shared.countryName(for: coordinate) }
        return GeneratedAlbumDraft(
            strategyID: draft.strategyID, placeName: name, places: [name], country: country,
            startDate: draft.startDate, endDate: draft.endDate, memberRefs: draft.memberRefs,
            coverRef: draft.coverRef, people: draft.people, latitude: draft.latitude, longitude: draft.longitude)
    }

    private var includeCloud: Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: AutoAlbumSettingsKeys.includeCloud) == nil
            ? true : ud.bool(forKey: AutoAlbumSettingsKeys.includeCloud)
    }

    private func cloudSignatureChanged() async -> Bool {
        guard includeCloud, let cloudProvider else { return false }
        let sig = Self.signature(of: await cloudProvider.cloudPhotos())
        return sig != lastCloudSignature
    }

    nonisolated private static func signature(of metas: [CloudPhotoMeta]) -> Int {
        // ⚠️ Swift の String.hashValue はプロセス毎に seed が変わり**起動を跨いで不安定**。
        // 署名を UserDefaults へ永続（Fix A）するため、決定的ハッシュ（FNV-1a）で算出する。
        // XOR は順序非依存なので集合の署名として安定する。
        var sig: UInt64 = 0
        for meta in metas where meta.latitude != nil { sig ^= stableHash(meta.path) }
        return Int(bitPattern: UInt(truncatingIfNeeded: sig))
    }

    /// 起動を跨いで安定な決定的ハッシュ（FNV-1a・UTF8）。
    nonisolated private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return h
    }

    private func ensurePhotoAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func ensureObserver() {
        guard observer == nil else { return }
        let obs = PhotoLibraryObserver { [weak self] in
            Task { @MainActor in self?.libraryDirty = true }
        }
        observer = obs
        PHPhotoLibrary.shared().register(obs)
    }
}

/// linkKey でローカル↔クラウドの同一写真を束ね、ローカルを優先する純ロジック（テスト対象）。
/// linkKey が nil の写真はそのまま残す。
func dedupByLinkKey(_ photos: [EnrichedPhoto]) -> [EnrichedPhoto] {
    var byLink: [String: EnrichedPhoto] = [:]
    var result: [EnrichedPhoto] = []
    for photo in photos {
        guard let link = photo.linkKey else { result.append(photo); continue }
        if let existing = byLink[link] {
            if !existing.isLocal && photo.isLocal { byLink[link] = photo }
        } else {
            byLink[link] = photo
        }
    }
    result.append(contentsOf: byLink.values)
    return result
}

private final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
