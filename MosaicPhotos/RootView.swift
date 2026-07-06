import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
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

    private init(dropboxStore: DropboxPhotoStore, mergedStore: MergedPhotoStore,
                 backupEngine: BackupEngine, albumScanner: LocalAlbumScanner,
                 peopleEngine: PeopleEngine,
                 placeScanner: PlaceScanner, autoAlbumEngine: AutoAlbumEngine) {
        self.dropboxStore = dropboxStore
        self.mergedStore = mergedStore
        self.backupEngine = backupEngine
        self.albumScanner = albumScanner
        self.peopleEngine = peopleEngine
        self.placeScanner = placeScanner
        self.autoAlbumEngine = autoAlbumEngine
    }

    /// 重いストアを順に構築する。各構築の前後で `Task.yield()` して主スレッドを解放し、
    /// 起動が 1 秒を超える場合でもローディング表示のタイマーが発火できるようにする。
    static func build() async -> HomeStores {
        Diagnostics.mark("build: start")
        let auth = DropboxAuthService(appKey: DropboxConfig.appKey, redirectURI: DropboxConfig.redirectURI)
        await Task.yield()
        let dropboxStore = DropboxPhotoStore(auth: auth)
        await Task.yield()
        let mergedStore = MergedPhotoStore(dropboxStore: dropboxStore)
        await Task.yield()
        let backupEngine = BackupEngine(auth: auth)
        await Task.yield()
        let albumScanner = LocalAlbumScanner()
        let peopleEngine = await makePeopleEngine()
        let placeScanner = PlaceScanner()
        await Task.yield()
        let autoAlbumEngine = await makeAutoAlbumEngine(dropboxStore: dropboxStore, backupEngine: backupEngine,
                                                        peopleEngine: peopleEngine)
        Diagnostics.mark("build: done")
        return HomeStores(dropboxStore: dropboxStore, mergedStore: mergedStore,
                          backupEngine: backupEngine, albumScanner: albumScanner,
                          peopleEngine: peopleEngine,
                          placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine)
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
            } else {
                LaunchView(showLoadingIndicator: showLoadingIndicator)
            }
        }
        // アプリ本体の Text リテラルはこのロケールで切り替わる。パッケージの L() は AppLocale を見る。
        .environment(\.locale, selectedLanguage == .system ? .autoupdatingCurrent
                                                            : Locale(identifier: selectedLanguage.rawValue))
        .onChange(of: appLanguageRaw) { _, _ in AppLocale.apply(selectedLanguage) }
        .task {
            // 1 秒経っても準備できなければローディングインジケータを出す。
            let loadingTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if stores == nil {
                    withAnimation(.easeIn(duration: 0.2)) { showLoadingIndicator = true }
                }
            }
            let built = await HomeStores.build()
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
                        ProgressView()
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
