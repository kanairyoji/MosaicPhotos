import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import MosaicSupport
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Root home view

struct HomeView: View {
    /// auth・dropboxStore・backupEngine の 3 つは同一の DropboxAuthService を共有する。
    /// mergedStore は dropboxStore を注入して共有 NSCache を維持する。
    /// @State の default value 式は相互参照できないため、カスタム init でまとめて初期化する。
    /// セクション構築は HomeSections.swift（extension）に分離しているため、そこから参照する
    /// プロパティは internal（private を付けない）にしている。
    @State var dropboxStore: DropboxPhotoStore
    @State private var mergedStore: MergedPhotoStore
    @State private var backupEngine: BackupEngine
    /// アルバムスキャナー。バックアップと独立してローカル写真ライブラリを走査・キャッシュする。
    @State var albumScanner: LocalAlbumScanner
    /// ピープル（人物＝顔アルバム）スキャナー。端末の写真アプリで名前を付けた人を取得する。
    @State var peopleEngine: PeopleEngine
    /// 場所（市区町村）スキャナー。ローカル＋Dropbox の位置情報をまとめてグルーピングする。
    @State var placeScanner: PlaceScanner
    /// 時間＋場所の自動アルバム生成エンジン（独立モジュール AutoAlbumCore）。
    /// Dropbox/バックアップのアダプタを注入し、ローカル＋クラウドを統合・重複排除して生成する。
    @State var autoAlbumEngine: AutoAlbumEngine
    /// フルスクリーン表示の対象（ソース/端末アルバム/場所/自動アルバム）。
    /// 4 つの `.fullScreenCover(item:)` を併用すると提示競合で別アルバムの中身が出る不具合があったため、
    /// 単一の `.fullScreenCover(item:)` ＋ enum に統合する（`.sheet` で採った対策と同じ）。
    @State var destination: HomeDestination?
    @State private var showingSettings = false
    /// AI アルバム作成/編集シートの対象（新規 or 既存）。
    /// 単一の `.sheet(item:)` に統合して、複数 .sheet 併用時の提示競合（編集が常に先頭になる不具合）を防ぐ。
    @State var aiComposer: AIComposerTarget?
    /// ピープルの長押しメニュー対象。配下の UI（名前変更／代表写真／顔の管理）は
    /// `PeopleActionsModifier`（Home/PeopleActions.swift）に分離している。
    @State var personActions: PersonInfo?
    /// フォルダ名アルバム機能の有効フラグ（ON のときだけ「Albums」セクションを出す）。
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) var pathAlbumsEnabled = false
    /// アクティビティバー表示時は、その分だけ上部に余白を確保してタイトルと重ならないようにする。
    @AppStorage(DropboxActivitySettingsKeys.showBar) private var activityBarShown = true
    /// デバッグ：シミュレータでも顔スキャンを走らせる（Developer Options）。ON にした瞬間に開始する。
    @AppStorage(AppSettingsKeys.faceScanOnSimulator) private var faceScanOnSimulator = false

    /// ストア一式（SettingsView / SourceHostView へ一括で渡す）。個別 @State は既存参照の互換用。
    let stores: HomeStores

    /// ストアは `HomeStores` で事前構築する（各ストアの `ModelContainer` 生成が同期的で重く、
    /// `HomeView.init` で作ると最初の描画＝起動をブロックするため）。`RootView` が起動直後に
    /// 非同期構築し、完成したものをここへ注入する。
    init(stores: HomeStores) {
        self.stores = stores
        self._dropboxStore = State(initialValue: stores.dropboxStore)
        self._mergedStore = State(initialValue: stores.mergedStore)
        self._backupEngine = State(initialValue: stores.backupEngine)
        self._albumScanner = State(initialValue: stores.albumScanner)
        self._peopleEngine = State(initialValue: stores.peopleEngine)
        self._placeScanner = State(initialValue: stores.placeScanner)
        self._autoAlbumEngine = State(initialValue: stores.autoAlbumEngine)
    }

    var body: some View {
        NavigationStack {
            List {
                sourceSection
                autoAlbumsSection
                peopleSection
                aiAlbumsSection
                pathAlbumsSection
                albumsSection
                placesSection
            }
            .listStyle(.insetGrouped)
            .onAppear { PerfTrace.endScreen("app.startup") }   // センサー: 起動→ホーム初回表示
            .safeAreaInset(edge: .bottom) { settingsBar }
            // システムの大タイトルはアクティビティバーと重なる（ナビバー chrome は safeAreaInset で
            // 下がらない）。ナビバーを隠し、バーの下に独自タイトルヘッダーを置いて重なりを解消する。
            .safeAreaInset(edge: .top, spacing: 0) { homeHeader }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(stores: stores)
            }
            .perfScreenEnd("home.settings")   // 計測: 設定シートを開く所要
        }
        .sheet(item: $aiComposer) { target in
            switch target {
            case .create:
                AIAlbumComposerView(engine: autoAlbumEngine)
            case .edit(let album):
                AIAlbumComposerView(engine: autoAlbumEngine, editing: album)
            }
        }
        .fullScreenCover(item: $destination) { dest in
            sourceHost(dismiss: { destination = nil }) {
                switch dest {
                case .source(.all):
                    PhotoSourceContentView(store: mergedStore, title: L("All Photos"))
                case .source(.local):
                    LocalPhotoContentView()
                case .source(.cloud):
                    DropboxContentView(store: dropboxStore)
                case .localAlbum(let album):
                    LocalPhotoContentView(localIdentifiers: album.localIdentifiers, title: album.name)
                case .person(let person):
                    // 通常の写真ビューア（グリッド→フル画面で上スワイプ＝EXIF/場所）。専用ページは作らない。
                    LocalPhotoContentView(localIdentifiers: localIdentifiers(from: person.memberRefKeys),
                                          title: person.displayName)
                case .place(let place):
                    PlacePhotosView(place: place, dropboxStore: dropboxStore)
                case .autoAlbum(let album):
                    AutoAlbumPhotosView(album: album, dropboxStore: dropboxStore)
                }
            }
            .perfScreenEnd("home.present")   // 計測: ホーム→各画面のフルスクリーン表示の所要
        }
        // 計測: 遷移トリガ（タップ）時刻を記録。begin と end の差が「画面遷移の重さ」。
        .onChange(of: destination?.id) { _, id in
            if id != nil { PerfTrace.beginScreen("home.present") }
        }
        .onChange(of: showingSettings) { _, on in
            if on { PerfTrace.beginScreen("home.settings") }
        }
        .modifier(HomeLifecycleTasks(
            dropboxStore: dropboxStore,
            backupEngine: backupEngine,
            placeScanner: placeScanner,
            albumScanner: albumScanner,
            peopleEngine: peopleEngine,
            autoAlbumEngine: autoAlbumEngine))
        // ピープル長押しメニュー（名前変更／代表写真の変更／顔の管理）と配下のシート/アラート一式。
        .peopleActions(for: $personActions, engine: peopleEngine)
        // Developer Options が ON のとき、ホーム最上部にも Dropbox 通信アクティビティを重ねる。
        .dropboxActivityBar()
        // デバッグ：シミュレータ顔スキャンのトグルを ON にしたら（起動後でも）その場で開始する。
        .task(id: faceScanOnSimulator) {
            guard faceScanOnSimulator else { return }
            peopleEngine.startScan(candidateRefKeys: await localImageRefKeys(), allowSimulator: true)
        }
    }

    // MARK: - Settings bar

    private var settingsBar: some View {
        HStack {
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
            .padding(.trailing, 20)
        }
        .frame(height: 49)
        .background(.bar)
    }

    /// ホーム上部の独自タイトルヘッダー（システムのナビバーは隠している）。
    /// アクティビティバー表示時はその分の余白を上に確保し、タイトルがバーへ潜り込まないようにする。
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if activityBarShown { Color.clear.frame(height: 30) }
            Text("MosaicPhotos")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Source host wrapper

    /// 各フルスクリーン表示で共有する `SourceHostView` ラッパー。共有ストアの注入は一定で、
    /// dismiss クロージャと中身（content）だけが異なるため、ここに集約して重複を排除する。
    @ViewBuilder
    private func sourceHost<Content: View>(
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SourceHostView(
            stores: stores,
            dismissToHome: dismiss,
            content: content
        )
    }
}

// MARK: - Lifecycle tasks

/// HomeView のバックグラウンド処理（スキャン/生成のロードと定期差分チェック、Dropbox 同期トリガ）を
/// 1 つの ViewModifier にまとめ、`body` のルーティング記述から分離する。
private struct HomeLifecycleTasks: ViewModifier {
    let dropboxStore: DropboxPhotoStore
    let backupEngine: BackupEngine
    let placeScanner: PlaceScanner
    let albumScanner: LocalAlbumScanner
    let peopleEngine: PeopleEngine
    let autoAlbumEngine: AutoAlbumEngine

    private var rescanIntervalSeconds: Int {
        let secs = UserDefaults.standard.integer(forKey: PlacesSettingsKeys.rescanIntervalSeconds)
        return secs > 0 ? secs : 10
    }

    func body(content: Content) -> some View {
        content
            // アルバムスキャン：キャッシュがあれば即ロード、なければバックグラウンドでスキャン。
            // バックアップとは独立して動作する。
            .task { await albumScanner.loadOrScan(); Diagnostics.mark("albums loaded") }
            // ピープル（人物＝顔アルバム）：キャッシュ即ロード→無ければスキャン。端末ライブラリのみ。
            .task {
                await peopleEngine.loadPeople()
                let allowSim = UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)
                peopleEngine.startScan(candidateRefKeys: await localImageRefKeys(), allowSimulator: allowSim)
            }
            // 場所スキャン：ローカル＋Dropbox（同期済みの位置情報）をグルーピング。
            // 初回ロード後は一定間隔で差分チェックし、Dropbox 側の座標が増えたら動的に再スキャンする
            // （バックグラウンド同期や写真閲覧で座標が補完されると Places アルバムが増える）。
            .task {
                // 起動直後の同時スパイクを避けるため初回 place スキャンを少し遅らせる（ホームの初回描画を優先）。
                try? await Task.sleep(for: .seconds(1.5))
                await placeScanner.loadOrScan(dropboxItems: dropboxStore.items)
                Diagnostics.mark("places loaded")
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(rescanIntervalSeconds))
                    // 電源＋回線ポリシーを満たすときだけ定期再スキャン（逆ジオコーディングは通信）を行う。
                    guard PowerStateMonitor.shared.backgroundAllowed(),
                          NetworkStateMonitor.shared.networkAllowed() else { continue }
                    await placeScanner.refreshIfNeeded(dropboxItems: dropboxStore.items)
                }
            }
            // 自動アルバム（時間＋場所）：キャッシュ即ロード→無ければ生成。以降は写真追加で再生成。
            .task {
                await autoAlbumEngine.loadOrGenerate()
                Diagnostics.mark("autoAlbum loadOrGenerate done")
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(rescanIntervalSeconds))
                    await autoAlbumEngine.refreshIfNeeded()
                }
            }
            // BackupSettingsView のデバッグ表示用のバックアップ記録ロードは起動表示に不要なので、
            // 起動スパイクを避けるため大きく遅延する（設定を開く頃には間に合う）。
            .task {
                try? await Task.sleep(for: .seconds(5))
                await backupEngine.loadAlbums()
            }
            .onChange(of: dropboxStore.auth.connectionStatus) { _, newStatus in
                switch newStatus {
                case .connected:
                    evaluateSync()
                case .notConnected, .error:
                    dropboxStore.reset()
                case .authenticating:
                    break
                }
            }
            // 電源・回線の変化で Dropbox 差分同期を起動/停止し、背景埋め込みを再開する
            //（電源復帰／Wi-Fi 復帰で保留分＝クラウド写真の埋め込みを拾い直す）。
            .onChange(of: PowerStateMonitor.shared.isOnPower) { _, _ in resumeBackgroundWork() }
            .onChange(of: PowerStateMonitor.shared.isLowPowerMode) { _, _ in resumeBackgroundWork() }
            .onChange(of: NetworkStateMonitor.shared.networkAllowed()) { _, _ in resumeBackgroundWork() }
            // 背景スキャンの稼働状況をアクティビティバーへ橋渡し（下位パッケージに依存を足さない）。
            .onChange(of: placeScanner.isScanning) { _, v in BackgroundActivityMonitor.shared.isScanningPlaces = v }
            .onChange(of: albumScanner.isScanning) { _, v in BackgroundActivityMonitor.shared.isScanningAlbums = v }
            .onAppear {
                if case .connected = dropboxStore.auth.connectionStatus {
                    evaluateSync()
                    let folder = UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder) ?? "/MosaicPhotos"
                    Task { await dropboxStore.loadBackupMetadata(from: folder) }
                }
            }
    }

    /// 電源・回線ポリシーに応じて Dropbox 差分同期を起動/停止する。接続中のみ対象。
    /// 「電源OK かつ 回線OK」なら同期を開始、そうでなければ停止して通信・電池を抑える。
    private func evaluateSync() {
        guard case .connected = dropboxStore.auth.connectionStatus else { return }
        if PowerStateMonitor.shared.backgroundAllowed() && NetworkStateMonitor.shared.networkAllowed() {
            dropboxStore.startSync()
        } else {
            dropboxStore.stopSync()
        }
    }

    /// 電源/回線が復帰したら、同期の再評価と背景埋め込みの再起動を行う。
    /// `scheduleBackgroundFill` は実行中なら no-op なので二重起動にはならない。
    private func resumeBackgroundWork() {
        evaluateSync()
        autoAlbumEngine.scheduleBackgroundFill()
    }
}
