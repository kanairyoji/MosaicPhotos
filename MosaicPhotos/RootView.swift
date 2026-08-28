import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotoSourceKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

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
    /// 共有サイドカーの解析供給アダプタ（shareEngine.analysisSource は weak のためここで保持）。
    let shareAnalysisAdapter: ShareAnalysisAdapter
    /// 作成元メンバーの解決役（sourceResolver は weak のためここで保持）。
    let shareSourceResolver: ShareSourceMemberResolver
    /// 家族フォルダのサイドカー取り込み（受信側）。
    let shareImporter: SharedAnalysisImporter
    /// PHAsset の全ライブラリ索引（アルバム系ビューの高速オープン用・段階起動で構築）。
    let assetIndex = LocalAssetIndex()

    private init(dropboxStore: DropboxPhotoStore, mergedStore: MergedPhotoStore,
                 backupEngine: BackupEngine, albumScanner: LocalAlbumScanner,
                 peopleEngine: PeopleEngine,
                 placeScanner: PlaceScanner, autoAlbumEngine: AutoAlbumEngine,
                 shareEngine: ShareSyncEngine, shareAnalysisAdapter: ShareAnalysisAdapter,
                 shareSourceResolver: ShareSourceMemberResolver,
                 shareImporter: SharedAnalysisImporter) {
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
        await Task.yield()
        let albumScanner = LocalAlbumScanner()
        let peopleEngine = await makePeopleEngine(dropboxStore: dropboxStore)
        let placeScanner = PlaceScanner()
        await Task.yield()
        let autoAlbumEngine = await makeAutoAlbumEngine(dropboxStore: dropboxStore, backupEngine: backupEngine,
                                                        peopleEngine: peopleEngine)
        await Task.yield()
        // 家族共有（ADR-112）: エンジン＋解析サイドカーの供給＋受信側の取り込み。
        let shareEngine = ShareSyncEngine(tokenProvider: auth,
                                          storeProvider: { await backupEngine.sharedBackupStore() })
        let shareAnalysisAdapter = ShareAnalysisAdapter(autoAlbumEngine: autoAlbumEngine,
                                                        peopleEngine: peopleEngine)
        shareEngine.analysisSource = shareAnalysisAdapter
        let shareSourceResolver = ShareSourceMemberResolver(peopleEngine: peopleEngine,
                                                           autoAlbumEngine: autoAlbumEngine)
        shareEngine.sourceResolver = shareSourceResolver
        // 顔を全消去すると clusterID が 0 から振り直される。人物を指す共有セットの参照は
        // 当てにならなくなるので外す（残すと別人の写真を家族フォルダへ足しかねない）。
        peopleEngine.onPersonIdentitiesInvalidated = { [weak shareEngine] in
            await shareEngine?.detachPersonSources()
        }
        let shareImporter = SharedAnalysisImporter(dropboxStore: dropboxStore,
                                                   autoAlbumEngine: autoAlbumEngine,
                                                   peopleEngine: peopleEngine)
        // バックアップコピーの二重表示を防ぐ（実機 diagnostics-57/58）。バックアップフォルダは
        // オフロード写真のクラウド代替のため同期対象に入れているが、**端末に原本が有る写真まで
        // 二重に出ていた**。台帳（パス → localIdentifier）を渡し、原本が有るものは隠す。
        mergedStore.backupCopyIndexProvider = { [weak backupEngine] in
            guard let store = await backupEngine?.sharedBackupStore() else { return [:] }
            // ⚠️ 全カラムを取らない（射影クエリ）。重複判定に要るのは 2 列だけで、
            // 起動時に全記録を materialize するとメモリの山になる。
            return await store.backupCopyIndex()
        }

        Diagnostics.mark("build: done")
        return HomeStores(dropboxStore: dropboxStore, mergedStore: mergedStore,
                          backupEngine: backupEngine, albumScanner: albumScanner,
                          peopleEngine: peopleEngine,
                          placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine,
                          shareEngine: shareEngine, shareAnalysisAdapter: shareAnalysisAdapter,
                          shareSourceResolver: shareSourceResolver,
                          shareImporter: shareImporter)
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
