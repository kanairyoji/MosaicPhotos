import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotoSourceKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI
import PeopleKit

// MARK: - Home stores (起動時に非同期構築する重いストア群)

/// `HomeView` が必要とするストア／エンジン一式。各ストアは `init` で同期的に
/// `ModelContainer`（SwiftData）を構築するため、まとめて作ると主スレッドを長くブロックし
/// 起動（最初の描画）が遅くなる。`build()` を起動直後の非同期パスで呼び、構築の合間に
/// `Task.yield()` を挟むことで、その間にローディング画面と「Now loading…」表示を描ける。
@MainActor
final class HomeStores {
    let dropboxStore: DropboxPhotoStore
    let mergedStore: MergedPhotoStore
    let backupEngine: BackupEngine
    let albumScanner: LocalAlbumScanner
    let peopleEngine: PeopleEngine
    let placeScanner: PlaceScanner
    let autoAlbumEngine: AutoAlbumEngine
    /// 家族共有（共有セット・ADR-112）。
    let shareEngine: ShareSyncEngine
    /// 共有解析データの解析供給アダプタ（shareEngine.analysisSource は weak のためここで保持）。
    let shareAnalysisAdapter: ShareAnalysisAdapter
    /// 作成元メンバーの解決役（sourceResolver は weak のためここで保持）。
    let shareSourceResolver: ShareSourceMemberResolver
    /// 家族フォルダの解析データ取り込み（受信側）。
    let shareImporter: SharedAnalysisImporter
    let analysisPublisher: CloudAnalysisPublisher
    /// PHAsset の全ライブラリ索引（アルバム系ビューの高速オープン用・段階起動で構築）。
    let assetIndex = LocalAssetIndex()
    /// 解析のブースト（「今すぐ解析」・ADR-182/195）。
    let analysisSession: AnalysisSession
    /// 常設の方針を評価して残作業を進める駆動役（ADR-195）。
    let analysisDriver: AnalysisDriver

    private init(dropboxStore: DropboxPhotoStore, mergedStore: MergedPhotoStore,
                 backupEngine: BackupEngine, albumScanner: LocalAlbumScanner,
                 peopleEngine: PeopleEngine,
                 placeScanner: PlaceScanner, autoAlbumEngine: AutoAlbumEngine,
                 shareEngine: ShareSyncEngine, shareAnalysisAdapter: ShareAnalysisAdapter,
                 shareSourceResolver: ShareSourceMemberResolver,
                 shareImporter: SharedAnalysisImporter,
                 analysisPublisher: CloudAnalysisPublisher) {
        let session = AnalysisSession(engine: autoAlbumEngine, people: peopleEngine,
                                      dropboxStore: dropboxStore)
        self.analysisSession = session
        self.analysisDriver = AnalysisDriver(engine: autoAlbumEngine, people: peopleEngine,
                                             dropboxStore: dropboxStore, session: session)
        self.dropboxStore = dropboxStore
        self.mergedStore = mergedStore
        self.backupEngine = backupEngine
        self.albumScanner = albumScanner
        self.peopleEngine = peopleEngine
        self.placeScanner = placeScanner
        self.autoAlbumEngine = autoAlbumEngine
        self.shareEngine = shareEngine
        self.shareAnalysisAdapter = shareAnalysisAdapter
        self.shareSourceResolver = shareSourceResolver
        self.shareImporter = shareImporter
        self.analysisPublisher = analysisPublisher
    }

    /// プロセス内で唯一の共有インスタンス（構築済み）。前景（RootView）と夜間 BGTask
    /// （`HeavyWorkScheduler`）が**別々に build すると PeopleEngine/AutoAlbumEngine が二重化**し、
    /// 顔スキャン・タグ付けが二重起動する（実障害＝起動毎に faces/tags start が 2 回）。
    @ObservationIgnored private static var shared: HomeStores?
    /// 構築中の in-flight タスク（同時要求を 1 本に集約する）。
    @ObservationIgnored private static var buildTask: Task<HomeStores, Never>?

    /// 共有インスタンスを返す（未構築なら 1 度だけ build・並行要求は同じタスクを待つ）。
    /// RootView と HeavyWorkScheduler はどちらもこれを使い、同一の store 群を共有する。
    static func shared() async -> HomeStores {
        if let shared { return shared }
        if let buildTask { return await buildTask.value }
        let task = Task { @MainActor in await build() }
        buildTask = task
        let result = await task.value
        shared = result
        buildTask = nil
        return result
    }

    /// 重いストアを順に構築する。各構築の前後で `Task.yield()` して主スレッドを解放し、
    /// 起動が 1 秒を超える場合でもローディング表示のタイマーが発火できるようにする。
    /// ※ 直接は呼ばず `shared()` 経由で使う（プロセス内で 1 度だけ構築するため）。
    static func build() async -> HomeStores {
        Diagnostics.mark("build: start")
        let auth = DropboxAuthService(appKey: DropboxConfig.appKey, redirectURI: DropboxConfig.redirectURI)
        await Task.yield()
        let dropboxStore = DropboxPhotoStore(auth: auth)
        // ADR-44: 同期対象＝「選択ソースフォルダ＋バックアップフォルダ」（常に両方）。
        // バックアップフォルダを含めることで、オフロードのクラウド代替・バックアップ済み
        // 写真の表示がソースフォルダ設定に左右されない。
        dropboxStore.syncRootsProvider = {
            let backupRoot = backupNormalizedPath(
                UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder)
                    ?? BackupSettingsKeys.defaultDropboxFolder)
            // 家族の共有フォルダ（ADR-112・受信側）も同期対象に含める（受信 ON のときだけ）。
            let familyRoots = ShareSettingsKeys.isReceiveEnabled()
                ? ShareSettingsKeys.currentFamilyFolders() : []
            return [DropboxSourceSettings.currentSourceFolder(), backupRoot] + familyRoots
        }
        // 送信側: 自分の共有ルートを表示から除外（原本と共有コピーの重複表示を防ぐ）。
        ShareVisibility.apply(to: dropboxStore)
        await Task.yield()
        let mergedStore = MergedPhotoStore(dropboxStore: dropboxStore)
        await Task.yield()
        let backupEngine = BackupEngine(auth: auth)
        // ADR-175: 配置の版が変わっていれば台帳をリセット（新配置 `Backup/` へ上げ直す）。
        // 起動直後・バックアップが動く前に 1 回だけ。
        await backupEngine.resetForLayoutChangeIfNeeded()
        // ADR-181: 夜間バックアップは背景 URLSession に持ち出す。眠っている間に終わった
        // 転送の応答もここで受け取る（settle は AppDelegate が結線済み）。
        backupEngine.backgroundUploads = BackgroundUploadSession.shared
        BackgroundUploadSession.shared.connect()
        await Task.yield()
        let albumScanner = LocalAlbumScanner()
        let peopleEngine = await makePeopleEngine(dropboxStore: dropboxStore)
        let placeScanner = PlaceScanner()
        await Task.yield()
        let autoAlbumEngine = await makeAutoAlbumEngine(dropboxStore: dropboxStore, backupEngine: backupEngine,
                                                        peopleEngine: peopleEngine)
        await Task.yield()
        // 家族共有（ADR-112）: エンジン＋解析データの供給＋受信側の取り込み。
        let shareEngine = ShareSyncEngine(tokenProvider: auth,
                                          storeProvider: { await backupEngine.sharedBackupStore() })
        let shareAnalysisAdapter = ShareAnalysisAdapter(autoAlbumEngine: autoAlbumEngine,
                                                        peopleEngine: peopleEngine)
        shareEngine.analysisSource = shareAnalysisAdapter
        let shareSourceResolver = ShareSourceMemberResolver(peopleEngine: peopleEngine,
                                                           autoAlbumEngine: autoAlbumEngine,
                                                           dropboxStore: dropboxStore)
        shareEngine.sourceResolver = shareSourceResolver
        // ⚠️ 共有の宛先名は**中身から決まる**（ADR-209）。クラウド原本（"C-"）の
        // content_hash は Dropbox の同期キャッシュが知っているので、そこから渡す。
        // 渡さないと refKey だけで名前が決まり、原本が差し替わっても気づけない。
        // ⚠️ **`items` から拾わない**（実機ログ diagnostics-84 で判明）。表示用の
        // `DropboxFileItem` は content_hash を**わざと持たない**ので、この表は常に空だった
        // ——クラウド原本の宛先名が「中身から決まる」はずが、実際には効いていない。
        // 台帳から 2 列だけの射影で取る。
        shareEngine.cloudSourceHashProvider = { [weak dropboxStore] in
            await dropboxStore?.cloudContentHashes() ?? [:]
        }
        // 顔を全消去すると clusterID が 0 から振り直される。人物を指す共有セットの参照は
        // 当てにならなくなるので外す（残すと別人の写真を家族フォルダへ足しかねない）。
        // 人物を手で直したら、人物条件を持つ AI アルバムから外れた写真を即座に落とす
        // （実フィードバック: AI アルバムで「XX ではない」を選んでも変化なし）。
        peopleEngine.onPeopleEdited = { [weak autoAlbumEngine] in
            await autoAlbumEngine?.pruneAIAlbumsAfterPeopleChange()
        }
        peopleEngine.onPersonIdentitiesInvalidated = { [weak shareEngine] in
            await shareEngine?.detachPersonSources()
        }
        let shareImporter = SharedAnalysisImporter(
            dropboxStore: dropboxStore, autoAlbumEngine: autoAlbumEngine,
            peopleEngine: peopleEngine,
            // 受け取った撮影日が増えたら、ホーム（All Photos）の並びを取り直す（ADR-199）。
            // ⚠️ **共有アルバムの画面には届かない**（レビュー指摘）。あの画面は
            // `forMembers` で自前のストアを持ち、索引を引くのは `start()` の 1 回だけ。
            // 開いたまま取り込みが走った場合は、閉じて開き直すまで古い並びのまま。
            // 未解決として `unresolved-problems.md` に記録した。
            onCaptureDatesChanged: { [weak mergedStore] in
                await mergedStore?.refreshBackupCopyIndex()
            })
        // バックアップコピーの二重表示を防ぐ（実機 diagnostics-57/58）。バックアップフォルダは
        // オフロード写真のクラウド代替のため同期対象に入れているが、**端末に原本が有る写真まで
        // 二重に出ていた**。台帳（パス → localIdentifier）を渡し、原本が有るものは隠す。
        mergedStore.backupCopyIndexProvider = { [weak backupEngine] in
            guard let store = await backupEngine?.sharedBackupStore() else { return [:] }
            // ⚠️ 全カラムを取らない（射影クエリ）。重複判定に要るのは 2 列だけで、
            // 起動時に全記録を materialize するとメモリの山になる。
            // ⚠️ 撮影日も一緒に渡す。Dropbox 側の日付は EXIF が読めない写真だと
            // **アップロード時刻**になるので、台帳の `creationDate` を正として上書きする
            // （ADR-128 追補・実フィードバック「バックアップを新しい写真と認識している」）。
            var index = await store.backupCopyRecords().mapValues {
                BackupCopyInfo(localIdentifier: $0.localIdentifier, captureDate: $0.captureDate)
            }
            // ⚠️ **受け取った共有写真の撮影日も同じ表に混ぜる**（ADR-199・実フィードバック
            // 「共有フォルダの表示が撮影時間順でない」）。上の台帳はバックアップのパスしか
            // 持たないので、家族フォルダ配下のパスは 1 件も当たらない。受信側で撮影日を
            // 復元できるのは解析データ（`Entry.d`）だけなので、そこから貯めた表を重ねる。
            // `localIdentifier` は nil＝**隠す対象にはしない**（原本は手元に無い）。
            for (path, date) in await Task.detached(priority: .utility, operation: {
                SharedCaptureDateStore().load()
            }).value where index[path] == nil {
                index[path] = BackupCopyInfo(localIdentifier: nil, captureDate: date)
            }
            return index
        }
        // ピープルの顔アバターが使うクラウド画像の取得先（PeopleKit の注入点）。
        // ⚠️ これを設定し忘れると、**クラウド写真の顔サムネが 1 枚も出ない**（レビュー画面が
        // 空のカードになる）。PeopleKit をパッケージへ出したとき実際に落として気づいた。
        // 取得は**キャッシュ済みのみ**（待たない・ADR-88）。無ければ**可視優先で取りに行かせる**
        // （待つのはビュー側のポーリング＝届いたら差し替わる）。
        // ⚠️ 以前は低優先の先読み（`prefetch`）で温めていたが、先読みは (1) 回線ポリシー
        //    （Wi-Fi のみ等）で黙って捨てられ、(2) 写真閲覧中（`isViewingPhoto`）は取り出されず、
        //    (3) グリッドのスクロールで取り消される。ユーザーが**いま見ている**顔の画像なので
        //    グリッドの可視セルと同じ扱い（FIFO・先読みより先）にする（実フィードバック:
        //    「似ている人」のサムネイルが更新されない）。待たない（fire-and-forget）ので
        //    ADR-88 の「行列に並ばされて画面が固まる」は起きない。
        PeopleImageSources.cachedCloudThumbnail = { [weak dropboxStore] path in
            await dropboxStore?.cachedThumbnail(for: dropboxFileItem(path: path))
        }
        PeopleImageSources.warmCloudThumbnail = { [weak dropboxStore] path in
            Task { _ = await dropboxStore?.thumbnail(for: dropboxFileItem(path: path)) }
        }

        // 解析候補（顔・タグ・埋め込み）でも同じ台帳で**端末に原本があるバックアップコピー**を外す
        // （表示と同じ重複排除。外さないとコピー側でもう一度解析し、分母が増え続ける）。
        AnalysisCandidates.backupCopyIndexProvider = mergedStore.backupCopyIndexProvider
        // 自分の共有ルート（クラウド共有のコピー）も解析しない——原本と解析結果はバックアップにある。
        AnalysisCandidates.excludedCloudPathPrefixes = ([ShareSettingsKeys.currentShareRoot()]
            + [ShareSettingsKeys.legacyShareRootIfAny()].compactMap { $0 }).map { $0.lowercased() }
        // 人物・グループ・場所・アルバムの**メンバー限定ストア**にも同じ索引を渡す
        // （渡していなかったので、それらの画面では副本が二重に出て並びも崩れていた）。
        MergedPhotoStore.defaultBackupCopyIndexProvider = mergedStore.backupCopyIndexProvider

        // 同じ Dropbox に繋がっている人へクラウド写真の解析を公開する（ADR-222・既定 ON）。
        let analysisPublisher = CloudAnalysisPublisher(dropboxStore: dropboxStore,
                                                       analysisSource: shareAnalysisAdapter)

        Diagnostics.mark("build: done")
        return HomeStores(dropboxStore: dropboxStore, mergedStore: mergedStore,
                          backupEngine: backupEngine, albumScanner: albumScanner,
                          peopleEngine: peopleEngine,
                          placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine,
                          shareEngine: shareEngine, shareAnalysisAdapter: shareAnalysisAdapter,
                          shareSourceResolver: shareSourceResolver,
                          shareImporter: shareImporter,
                          analysisPublisher: analysisPublisher)
    }
}

// MARK: - Root view

/// アプリのルート。起動直後に `HomeStores` を非同期構築し、完成したら `HomeView` を表示する。
/// 構築が 1 秒を超えたら「Now loading…」を表示する（高速起動ではローディングを出さない）。
struct RootView: View {
    @State private var stores: HomeStores?
    @State private var showLoadingIndicator = false
    @AppStorage(AppLocale.key) private var appLanguageRaw = AppLanguage.system.rawValue

    private var selectedLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .system }

    var body: some View {
        Group {
            if let stores {
                HomeView(stores: stores)
                    // アルバム/人物の「家族と共有…」が参照する（ADR-112）。
                    .environment(stores.shareEngine)
            } else {
                LaunchView(showLoadingIndicator: showLoadingIndicator)
            }
        }
        // アプリ本体の Text リテラルはこのロケールで切り替わる。パッケージの L() は AppLocale を見る。
        .environment(\.locale, selectedLanguage == .system ? .autoupdatingCurrent
                                                            : Locale(identifier: selectedLanguage.rawValue))
        .onChange(of: appLanguageRaw) { _, _ in AppLocale.apply(selectedLanguage) }
        .task { TouchActivityTracker.install() }
            .task {
            // 1 秒経っても準備できなければローディングインジケータを出す。
            let loadingTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if stores == nil {
                    withAnimation(.easeIn(duration: 0.2)) { showLoadingIndicator = true }
                }
            }
            let built = await HomeStores.shared()
            stores = built
            // ロック中実行（BGProcessingTask）が同じストア群を再利用できるよう共有する。
            HeavyWorkScheduler.stores = built
            loadingTimer.cancel()
            // 起動時は scenePhase の変化が来ないので、駆動役の前面監視をここで始める（ADR-195）。
            // 起動時の起こし（`.launch`）は HomeView 側＝人物のロード後に 1 回だけ。
            built.analysisDriver.startIdleWatch()
        }
    }
}

// MARK: - Launch view

/// 起動中のスプラッシュ。1 秒未満で準備できれば素通りし、超えた場合のみ
/// `showLoadingIndicator` でスピナーと「Now loading…」を出す。
private struct LaunchView: View {
    let showLoadingIndicator: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("MosaicPhotos")
                    .font(.title2.weight(.semibold))

                if showLoadingIndicator {
                    VStack(spacing: 10) {
                        // ⚠️ 起動画面こそフレーム駆動では困る（ADR-96）。ストア構築・68,200 件の
                        //    読み込み・アルバム生成が重なる区間なので、メインが止まっても
                        //    回り続ける `BusySpinner`（CAAnimation）にする。
                        BusySpinner(style: .large)
                        Text("Now loading…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}
