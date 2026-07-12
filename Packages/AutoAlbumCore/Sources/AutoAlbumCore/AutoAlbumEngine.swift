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
    @ObservationIgnored private var lastCloudSignature = 0
    /// ユーザーが写真を能動操作中か（スクラブ等）。背景 CLIP 埋め込みを一時停止するために使う（G）。
    /// Recognition extension から参照するため internal。
    @ObservationIgnored var isInteracting = false
    /// T5: AI アルバム再評価の時間スロットル用（Recognition extension が参照）。
    @ObservationIgnored var lastAIRefreshAt = Date.distantPast
    /// Phase 2: スロットル中に蓄積する「新規に埋め込まれた refKey」（増分再評価の入力）。
    @ObservationIgnored var pendingNewEmbeds: [String] = []

    @ObservationIgnored let labelProvider: LabelProvider?
    /// シーンタグ・キャプションのストア／トリクル付与（TagsV1 別コンテナ）。
    @ObservationIgnored let tagStore: TagStore
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
        return AutoAlbumEngine(cloudProvider: cloudProvider, backupLink: backupLink,
                               peopleProvider: peopleProvider, queryUnderstanding: queryUnderstanding,
                               perception: perception, textEmbedder: textEmbedder,
                               translator: translator, labelProvider: labelProvider, store: store,
                               tagStore: tagStore, tagProvider: tagProvider)
    }

    init(cloudProvider: CloudPhotoProvider? = nil, backupLink: BackupLinkProvider? = nil,
         peopleProvider: PeopleProvider? = nil, queryUnderstanding: QueryUnderstanding? = nil,
         perception: PhotoPerceptionProvider? = nil, textEmbedder: TextEmbedder? = nil,
         translator: QueryTranslator? = nil, labelProvider: LabelProvider? = nil,
         store: AutoAlbumStore? = nil, tagStore: TagStore? = nil,
         tagProvider: TagPerceptionProvider? = nil) {
        let store = store ?? AutoAlbumStore()
        let tagStore = tagStore ?? TagStore()
        self.tagStore = tagStore
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
        self.pathGenerator = PathAlbumGenerator(store: store, cloudProvider: cloudProvider)
        self.tagger = PhotoTagger(store: store, perception: perception)
    }

    public func enrichmentCount() async -> Int { await store.enrichmentCount() }

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
    private static let perceptionVersion = 7   // v7: 同梱モデルを OpenCLIP ViT-B-32/DataComp(MIT) へ差替→全再埋め込み

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
        Self.log.info("loadOrGenerate: scheduling background tagging")
        scheduleBackgroundFill()
    }

    /// バックグラウンド自動生成が有効で、ローカル/クラウドに変化があれば再生成する（定期ティック用）。
    public func refreshIfNeeded() async {
        guard isLoaded, !isGenerating else { return }
        // 重い処理の共通方針: 電源接続＋低電力 OFF＋一定時間アイドルのときだけ動かす
        // （人が使っている気配がある間は背景でも動かさない・次のティックで再判定）。
        guard BackgroundYield.heavyWorkAllowed else { return }

        // プレビューのままの AI アルバムを本番化（FM 解釈＋LLM 審査つきフル評価）。
        // 作成時は決定的プレビューだけ出す方針のため、本番化はこのゲート内（夜間）で行う。
        aiAlbums = await aiService.finalizePending(aiAlbums)

        // AI アルバムのドリフト検知（自動生成トグルとは独立）：埋め込みの進行に対して
        // 評価済み時点が大きく遅れていたらフル再評価で整合を回復する（LLM は走らない）。
        if let refreshed = await aiService.refreshIfDrifted(aiAlbums) {
            aiAlbums = refreshed
        }

        guard UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.backgroundEnabled) else { return }
        let cloudChanged = await cloudSignatureChanged()
        guard libraryDirty || cloudChanged else { return }
        libraryDirty = false
        await generate()
    }

    public func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false; isLoaded = true }

        Self.log.info("generate: begin")
        let t0 = Date()
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

        // 3. 現存しない写真の付加情報を削除。既存ローカルの linkKey をバックアップ最新で更新。
        Diagnostics.mark("generate.step3: prune…")
        await store.prune(keeping: currentRefKeys)
        await store.refreshLocalLinkKeys(backupMap)

        // 4〜6. 重複排除・旅行抽出・フォルダ名アルバムは 85k 件規模の純計算。
        //    まとめて Task.detached（オフメイン）で行い、メインは結果の代入だけにする
        //    （従来はエンジン＝@MainActor 上で実行され、実測で main を最大 12 秒塞いでいた）。
        //    生成は意味検索を伴わないため clipVector を載せない軽量版を使う（実機メモリ削減）。
        Diagnostics.mark("generate.step4: fetch lite…")
        let allEnriched = await store.allEnrichedPhotosLite()
        Diagnostics.mark("generate.step4: lite=\(allEnriched.count) → detached compute…")
        let excludeAlbumed = UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.excludeAlbumed)
        let albumed = excludeAlbumed ? await PhotoEnricher.userAlbumedIdentifiers() : []
        let params = AlbumGenParams.current
        let strategies = self.strategies

        let (photos, infos, pathInfos) = await Task.detached(priority: .utility)
        { () -> ([EnrichedPhoto], [AutoAlbumInfo], [AutoAlbumInfo]) in
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
            return (photos, infos, pathInfos)
        }.value

        Diagnostics.mark("generate.step5: compute done → save…")
        await PlaceNameResolver.shared.persist()
        await store.replaceAlbums(forStrategy: TimePlaceStrategy.strategyID, with: infos)
        await store.replaceAlbums(forStrategy: PathAlbumStrategy.strategyID, with: pathInfos)
        albums = infos
        pathAlbums = pathInfos
        UserDefaults.standard.set(Self.generationVersion, forKey: AutoAlbumSettingsKeys.generationVersion)
        status = "\(infos.count) trips · \(pathInfos.count) folders · \(photos.count) photos"
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        Self.log.info("generate: end in \(secs)s — \(infos.count) trips, \(pathInfos.count) folders, \(photos.count) photos")
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
        var sig = 0
        for meta in metas where meta.latitude != nil { sig ^= meta.path.hashValue }
        return sig
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
