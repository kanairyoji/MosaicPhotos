import CoreLocation
import Foundation
import MosaicSupport
import Observation
import Photos
import PhotoSourceKit

/// 自動アルバム生成のオーケストレーション（@Observable ファサード）。
/// 公開状態（各アルバム配列・フラグ）を保持し、実処理は協調オブジェクトへ委譲する：
/// - エンリッチ＋時間＋場所生成: 本体（`generate`）
/// - AI アルバム: `AIAlbumService`
/// - フォルダ名アルバム: `PathAlbumGenerator`
/// - Vision タグ付け: `PhotoTagger`
@MainActor
@Observable
public final class AutoAlbumEngine {

    public private(set) var albums: [AutoAlbumInfo] = []
    /// フォルダ名（Dropbox パス）から推測したアルバム（時間＋場所とは別セクション）。
    public private(set) var pathAlbums: [AutoAlbumInfo] = []
    /// 自然文から作る AI アルバム（ユーザー作成・保存）。
    public private(set) var aiAlbums: [AutoAlbumInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isGenerating = false
    /// フォルダ名アルバムだけの軽量再生成中フラグ（地名解決を伴わないので速い）。
    public private(set) var isGeneratingPath = false
    /// Vision/CLIP タグ付けの実行中フラグ（UI のスピナー用）。
    public private(set) var isTagging = false
    public private(set) var status: String = ""

    @ObservationIgnored private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Engine")
    @ObservationIgnored private let store: AutoAlbumStore
    @ObservationIgnored private let enricher = PhotoEnricher()
    @ObservationIgnored private let strategies: [AlbumStrategy] = [TimePlaceStrategy()]
    @ObservationIgnored private let cloudProvider: CloudPhotoProvider?
    @ObservationIgnored private let backupLink: BackupLinkProvider?
    @ObservationIgnored private let peopleProvider: PeopleProvider?
    @ObservationIgnored private let aiService: AIAlbumService
    @ObservationIgnored private let pathGenerator: PathAlbumGenerator
    @ObservationIgnored private let tagger: PhotoTagger
    @ObservationIgnored private var observer: PhotoLibraryObserver?
    @ObservationIgnored private var libraryDirty = false
    @ObservationIgnored private var lastCloudSignature = 0

    @ObservationIgnored private let labelProvider: LabelProvider?

    public init(cloudProvider: CloudPhotoProvider? = nil, backupLink: BackupLinkProvider? = nil,
                peopleProvider: PeopleProvider? = nil, queryUnderstanding: QueryUnderstanding? = nil,
                perception: PhotoPerceptionProvider? = nil, textEmbedder: TextEmbedder? = nil,
                translator: QueryTranslator? = nil, labelProvider: LabelProvider? = nil) {
        let store = AutoAlbumStore()
        self.store = store
        self.cloudProvider = cloudProvider
        self.backupLink = backupLink
        self.peopleProvider = peopleProvider
        self.labelProvider = labelProvider
        self.aiService = AIAlbumService(store: store,
                                        understanding: queryUnderstanding ?? makeDefaultQueryUnderstanding(),
                                        textEmbedder: textEmbedder,
                                        translator: translator)
        self.pathGenerator = PathAlbumGenerator(store: store, cloudProvider: cloudProvider)
        self.tagger = PhotoTagger(store: store, perception: perception)
    }

    public func enrichmentCount() async -> Int { await store.enrichmentCount() }

    /// 写真（`PhotoItem.id`）の付加情報（キャプション/人物/解析状態）。フル画像ビューの表示用。
    /// `id` の形式はソースで異なる：MergedPhotoItem は既に "L-…"/"C-…"（refKey そのもの）、
    /// LocalPhotoItem は生の localIdentifier、DropboxFileItem は生の path。すべてに対応する。
    public func insight(forItemID id: String) async -> PhotoInsight? {
        for refKey in Self.candidateRefKeys(for: id) {
            guard let rec = await store.insightRecord(refKey: refKey) else { continue }
            let status: PhotoInsight.Status = rec.tagged ? .ready : .analyzing
            // 表示専用タグ：保存済み CLIP ベクトルに対するゼロショット（検索は語彙ゼロのまま）。
            var tags: [String] = []
            if let vector = rec.photo.clipVector, let labelProvider {
                tags = await labelProvider.labels(forEmbedding: vector)
            }
            return PhotoInsight(tags: tags, people: rec.photo.people, status: status)
        }
        // 付加情報が無い＝まだ取り込まれていない。
        return PhotoInsight(status: .notIndexed)
    }

    /// id（生 localIdentifier / 生 path / 既に refKey）→ 試す refKey 候補。
    private static func candidateRefKeys(for id: String) -> [String] {
        var keys: [String] = []
        if PhotoRef.decode(id) != nil { keys.append(id) }
        keys.append(PhotoRef.local(id).encoded)
        keys.append(PhotoRef.cloud(id).encoded)
        return keys
    }

    // MARK: - AI albums

    public func createAIAlbum(title: String, criteria: String) async -> AIAlbumResult {
        await makeAIAlbum(id: "\(AIAlbumStrategy.strategyID):\(UUID().uuidString)", title: title, criteria: criteria)
    }

    /// 既存 AI アルバムを再設定（タイトル・条件を変更して作り直す）。id を維持して上書きする。
    public func updateAIAlbum(id: String, title: String, criteria: String) async -> AIAlbumResult {
        await makeAIAlbum(id: id, title: title, criteria: criteria)
    }

    public func deleteAIAlbum(id: String) async {
        aiAlbums = await aiService.delete(id: id)
    }

    private func makeAIAlbum(id: String, title: String, criteria: String) async -> AIAlbumResult {
        let (result, albums) = await aiService.make(id: id, title: title, criteria: criteria)
        if let albums { aiAlbums = albums }
        if case .created = result { scheduleBackgroundFill() }   // 取り込み途中でも背景で埋める
        return result
    }

    /// 保存済み AI アルバムを現在のインデックスで再評価する。
    private func refreshAIAlbums() async {
        aiAlbums = await aiService.refresh(aiAlbums)
    }

    /// 未タグ写真の Vision タグ付け＋AI アルバム再評価をバックグラウンドで進める（非ブロッキング）。
    /// QoS は `.background`：UI 操作（.userInitiated）と CPU を奪い合わず、OS が優先度を下げる。
    private func scheduleBackgroundFill() {
        let preset = Self.currentBackgroundPreset()
        Task(priority: .background) {
            isTagging = true
            await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                          betweenBatchNs: preset.betweenBatchNs) {
                [weak self] in await self?.refreshAIAlbums()
            }
            isTagging = false
        }
    }

    /// 設定（重さ段階）から現在のバックグラウンド埋め込みプリセットを読む。
    static func currentBackgroundPreset() -> BackgroundProcessingPreset {
        let index = UserDefaults.standard.object(forKey: AutoAlbumSettingsKeys.backgroundProcessingLevel) as? Int
            ?? BackgroundProcessing.defaultIndex
        return BackgroundProcessing.preset(at: index)
    }

    /// 埋め込み済み／未処理の写真数（設定画面の進捗表示用）。
    public func recognitionCounts() async -> (tagged: Int, untagged: Int) {
        async let tagged = store.embeddedCount()
        async let untagged = store.unembeddedCount()
        return (await tagged, await untagged)
    }

    /// 全写真の認識結果（CLIP 埋め込み・キャプション）を消去し、最新ロジックで一から付け直す。
    /// 「再解析」用。完了まで await する（UI はスピナー表示）。
    public func reanalyzePhotos() async {
        guard !isTagging else { return }
        await store.clearPerception()
        let preset = Self.currentBackgroundPreset()
        isTagging = true
        await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                      betweenBatchNs: preset.betweenBatchNs) {
            [weak self] in await self?.refreshAIAlbums()
        }
        isTagging = false
    }

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
    private static let generationVersion = 3

    /// タグ付け（Vision/CLIP 知覚）ロジックのバージョン。抽出の改善時に上げると、起動時に1回だけ
    /// 全ローカル写真の sceneTagged をリセットして付け直す（メタデータ・地名は保持）。
    private static let perceptionVersion = 6

    public func loadOrGenerate() async {
        ensureObserver()
        if albums.isEmpty && pathAlbums.isEmpty && aiAlbums.isEmpty {
            let all = await store.allAlbums()
            albums = all.filter { $0.strategyID == TimePlaceStrategy.strategyID }
            pathAlbums = all.filter { $0.strategyID == PathAlbumStrategy.strategyID }
            aiAlbums = all.filter { $0.strategyID == AIAlbumStrategy.strategyID }
        }
        isLoaded = true
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
        // メタデータが揃った時点で AI アルバムを再評価し、続けて Vision タグ付け＋再評価を背景で進める。
        await refreshAIAlbums()
        Self.log.info("loadOrGenerate: scheduling background tagging")
        scheduleBackgroundFill()
    }

    /// バックグラウンド自動生成が有効で、ローカル/クラウドに変化があれば再生成する（定期ティック用）。
    public func refreshIfNeeded() async {
        guard isLoaded, !isGenerating else { return }
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
        if includeCloud, let cloudProvider {
            let metas = await cloudProvider.cloudPhotos()
            lastCloudSignature = Self.signature(of: metas)
            let cloudResult = await enricher.enrichCloud(metas: metas, existing: existing)
            await store.upsert(cloudResult.new)
            currentRefKeys.formUnion(cloudResult.current)
        }

        // 3. 現存しない写真の付加情報を削除。既存ローカルの linkKey をバックアップ最新で更新。
        await store.prune(keeping: currentRefKeys)
        await store.refreshLocalLinkKeys(backupMap)

        // 4. 全付加情報 → 重複排除（linkKey でローカル優先）。
        let allEnriched = await store.allEnrichedPhotos()
        var photos = dedupByLinkKey(allEnriched)
        if UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.excludeAlbumed) {
            let albumed = await PhotoEnricher.userAlbumedIdentifiers()
            photos = photos.filter { ref in
                guard let localId = PhotoRef.decode(ref.id)?.localIdentifier else { return true }
                return !albumed.contains(localId)
            }
        }

        // 5. 各戦略で時間＋場所アルバム化（地名が空なら代表座標を逆ジオコーディングして補完）。
        let params = AlbumGenParams.current
        var infos: [AutoAlbumInfo] = []
        for strategy in strategies {
            for rawDraft in strategy.makeAlbums(from: photos, params: params) {
                let draft = await resolvePlaceIfNeeded(rawDraft)
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
        await PlaceNameResolver.shared.persist()
        infos.sort { $0.representativeDate > $1.representativeDate }

        // 6. フォルダ名アルバム（任意・既定 OFF）。戦略ごとに差し替え（AI アルバムなど保存物は消さない）。
        let pathInfos = pathGenerator.makeFromEnriched(allEnriched)
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
    private func resolvePlaceIfNeeded(_ draft: GeneratedAlbumDraft) async -> GeneratedAlbumDraft {
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

    private static func signature(of metas: [CloudPhotoMeta]) -> Int {
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
