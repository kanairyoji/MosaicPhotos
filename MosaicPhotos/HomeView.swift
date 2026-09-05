import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import MosaicSupport
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI
import PeopleKit

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
    let assetIndex: LocalAssetIndex
    /// 人物レビュー（「同じ人物？」確認カード・ADR-46）のシート表示。
    @State var showingFaceReview = false
    @State var showingAllPeople = false
    /// 写真の地図（Places セクションのヘッダーから開く）。
    @State var showingPhotoMap = false
    @State var showingBatchReview = false
    /// 確認ボタンの方式選択（一人ずつ / まとめて）。
    @State var showingReviewChooser = false
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
    /// ピープルグループの長押しメニュー対象と作成シート（Home/PeopleGroupViews.swift）。
    @State var peopleGroupActions: PeopleGroupInfo?
    @State var showingGroupCreation = false
    /// クラウド共有で受け取ったアルバム（家族フォルダ配下の共有セット・ある場合のみセクション表示）。
    @State var sharedAlbums: [SharedAlbumDiscovery.Album] = []
    /// 共有中バッジの対象 ID。共有セットが変わったときだけ作り直す（body で計算しない）。
    @State var cloudSharedBadges = CloudSharedBadges()
    /// フォルダ名アルバム機能の有効フラグ（ON のときだけ「Albums」セクションを出す）。
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) var pathAlbumsEnabled = false
    /// アクティビティバー表示時は、その分だけ上部に余白を確保してタイトルと重ならないようにする。
    @AppStorage(DropboxActivitySettingsKeys.showBar) private var activityBarShown = true
    /// デバッグ：シミュレータでも顔スキャンを走らせる（Developer Options）。ON にした瞬間に開始する。
    @AppStorage(AppSettingsKeys.faceScanOnSimulator) private var faceScanOnSimulator = false

    /// ストア一式（SettingsView / SourceHostView へ一括で渡す）。個別 @State は既存参照の互換用。
    let stores: HomeStores

    /// 共有中バッジの対象 ID を作り直す（呼ばれるのは共有セット/グループの変更時だけ）。
    /// body の計算プロパティにすると再描画のたびに数千人物・数百アルバムを走査してしまう。
    func updateCloudSharedBadges() {
        let fresh = CloudSharedBadges.resolve(
            sets: stores.shareEngine.sets,
            people: peopleEngine.people,
            groups: peopleEngine.peopleGroups,
            albums: autoAlbumEngine.albums + autoAlbumEngine.aiAlbums)
        if fresh != cloudSharedBadges { cloudSharedBadges = fresh }
    }

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
        self.assetIndex = stores.assetIndex
    }

    var body: some View {
        // ⚠️ **式を小さく保つ**。ここに 20 個以上の modifier を直につなぐと 1 つの巨大な型式になり、
        // 型検査が現実的な時間で終わらない（ピープル UI をパッケージへ出して型の解決が増えた
        // ときに実際に止まった）。土台と提示を分け、提示もさらに 2 つに割る。
        peoplePresentations(basePresentations(homeStack))
    }

    /// ホームの土台（一覧そのもの）。
    private var homeStack: some View {
        NavigationStack {
            List {
                sourceSection
                autoAlbumsSection
                peopleSection
                cloudSharedSection
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
    }


    /// 遷移先の画面（`HomeDestination` → View）。
    /// ⚠️ cover のクロージャに switch を直書きすると、型検査が現実的な時間で終わらない。
    @ViewBuilder
    private func destinationView(_ dest: HomeDestination) -> some View {
        switch dest {
        case .source(.all):
            PhotoSourceContentView(store: mergedStore, title: L("All Photos"))
        case .source(.local):
            LocalPhotoContentView()
        case .source(.cloud):
            DropboxContentView(store: dropboxStore)
        case .localAlbum(let album):
            // 端末アルバム＝ローカル現存分＋オフロード済みクラウド代替の合成表示（ADR-39）。
            // 台帳が空なら従来のローカルのみ表示と完全に同じ。
            DeviceAlbumPhotosView(album: album, dropboxStore: dropboxStore,
                                  backupEngine: backupEngine, assetIndex: assetIndex)
        case .person(let person):
            // メンバー限定 MergedPhotoStore で端末＋クラウド両方のメンバーを表示（PlacePhotosView と同型）。
            PersonAlbumView(person: person, dropboxStore: dropboxStore, assetIndex: assetIndex,
                            peopleEngine: peopleEngine)
        case .peopleGroup(let group):
            // グループ（複数人の束）の合成アルバム。
            PeopleGroupAlbumView(group: group, dropboxStore: dropboxStore,
                                 assetIndex: assetIndex, peopleEngine: peopleEngine)
        case .sharedAlbum(let album):
            // クラウド共有で受け取ったアルバム（家族フォルダ配下の 1 フォルダ）。
            SharedAlbumPhotosView(album: album, dropboxStore: dropboxStore,
                                  assetIndex: assetIndex)
        case .place(let place):
            PlacePhotosView(place: place, dropboxStore: dropboxStore, assetIndex: assetIndex)
        case .autoAlbum(let album):
            // AI アルバムは画面内「…」からも削除できる（ホームカードの操作と統一）。
            AutoAlbumPhotosView(album: album, dropboxStore: dropboxStore, assetIndex: assetIndex,
                onDelete: album.strategyID == AIAlbumStrategy.strategyID
                    ? { Task { await autoAlbumEngine.deleteAIAlbum(id: album.id) }; destination = nil }
                    : nil)
        }
    }

    /// 設定・AI コンポーザ（`@State` の Binding を使うのでメソッド）。
    @ViewBuilder
    private func basePresentations<V: View>(_ content: V) -> some View {
        destinationPresentation(content
        // 画面遷移・設定シートはユーザー操作としてアイドル判定に記録する（重い処理の抑制）。
        .onChange(of: destination == nil) { _, _ in BackgroundActivityMonitor.shared.noteUserInteraction() }
        .onChange(of: showingSettings) { _, _ in BackgroundActivityMonitor.shared.noteUserInteraction() }
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
        )
    }

    /// 各画面へのフルスクリーン遷移と、共有バッジの更新。
    @ViewBuilder
    private func destinationPresentation<V: View>(_ content: V) -> some View {
        sharePresentations(content
        .fullScreenCover(item: $destination) { dest in
            sourceHost(dismiss: { destination = nil }) {
                destinationView(dest)
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
            autoAlbumEngine: autoAlbumEngine,
            assetIndex: assetIndex,
            shareEngine: stores.shareEngine,
            shareImporter: stores.shareImporter))
        // バッジ対象 ID は**共有セット/グループが変わったときだけ**作り直す（body で計算しない）。
        .task { updateCloudSharedBadges() }
        .onChange(of: stores.shareEngine.sets) { _, _ in updateCloudSharedBadges() }
        .onChange(of: peopleEngine.peopleGroups) { _, _ in updateCloudSharedBadges() }
        // ピープル長押しメニュー（名前変更／代表写真の変更／顔の管理）と配下のシート/アラート一式。
        )
    }

    /// 共有・ピープルのメニュー系（長押しメニュー・作成シート・受信共有の発見）。
    @ViewBuilder
    private func sharePresentations<V: View>(_ content: V) -> some View {
        content
        .peopleActions(for: $personActions, engine: peopleEngine)
        // ピープルグループの長押しメニュー（編集/クラウド共有/削除）と作成シート。
        .peopleGroupActions(for: $peopleGroupActions, engine: peopleEngine)
        .sheet(isPresented: $showingGroupCreation) {
            PeopleGroupEditorSheet(peopleEngine: peopleEngine)
        }
        // 受信共有アルバムの発見。同期の進行（items の増減）と家族フォルダ設定に追従する。
        // 68k 件の走査なのでオフメインで行い、メインへは結果だけ返す。
        .task(id: dropboxStore.items.count) {
            let items = dropboxStore.items
            let roots = ShareSettingsKeys.isReceiveEnabled()
                ? ShareSettingsKeys.currentFamilyFolders() : []
            guard !roots.isEmpty else {
                if !sharedAlbums.isEmpty { sharedAlbums = [] }
                return
            }
            let albums = await Task.detached(priority: .utility) {
                SharedAlbumDiscovery.albums(itemPaths: items.map(\.path), familyRoots: roots)
            }.value
            if albums != sharedAlbums { sharedAlbums = albums }
        }
    }

    /// ピープル・地図・共有まわりの提示（続き）。
    @ViewBuilder
    private func peoplePresentations<V: View>(_ content: V) -> some View {
        content
        // 確認方式の選択（一人ずつ＝1対1カード / まとめて＝類似クラスタの一括確認）。
        .confirmationDialog(L("Review People"), isPresented: $showingReviewChooser,
                            titleVisibility: .visible) {
            Button(L("One by one")) { showingFaceReview = true }
            Button(L("All at once")) { showingBatchReview = true }
            Button(L("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showingFaceReview) {
            FaceReviewView(peopleEngine: peopleEngine)
        }
        // 人物が多すぎてカルーセルに収まらないときの全一覧（ADR-68）。
        // 写真の地図（Places セクションのヘッダーから開く・ADR-127）。
        .fullScreenCover(isPresented: $showingPhotoMap) {
            PhotoMapView(dropboxStore: dropboxStore, placeScanner: placeScanner, assetIndex: assetIndex)
        }
        .sheet(isPresented: $showingAllPeople) {
            AllPeopleView(peopleEngine: peopleEngine, people: peopleEngine.people,
                          onSelect: { destination = .person($0) },
                          onLongPress: { personActions = $0 },
                          onBatchReview: {
                              showingAllPeople = false
                              showingBatchReview = true
                          })
        }
        // まとめて確認（1 画面で多数のクラスタを畳む・ADR-68）。
        .sheet(isPresented: $showingBatchReview) {
            FaceBatchReviewView(peopleEngine: peopleEngine)
        }
        // Developer Options が ON のとき、ホーム最上部にも Dropbox 通信アクティビティを重ねる。
        .dropboxActivityBar()
        // デバッグ：シミュレータ顔スキャンのトグルを ON にしたら（起動後でも）その場で開始する。
        .task(id: faceScanOnSimulator) {
            guard faceScanOnSimulator else { return }
            peopleEngine.startScan(candidateRefKeys: await analysisOrderedRefKeys(dropboxStore: dropboxStore), allowSimulator: true)
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
        // ⚠️ **どの写真ビューでも人物を直せるようにする**（実フィードバック: 「AI アルバムで
        // 家族の束を見ていて、家族じゃない写真があると気づいたときに直したい」）。
        // 1 人だけ写っている写真の長押し／全画面メニューに「この人は XX ではない」「別の人…」が出る。
        // 人物アルバムは自前の操作を持つので、そちら側で上書きしている。
        .photoPersonActions(peopleEngine: stores.peopleEngine)
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
    let assetIndex: LocalAssetIndex
    let shareEngine: ShareSyncEngine
    let shareImporter: SharedAnalysisImporter

    private var rescanIntervalSeconds: Int {
        let secs = UserDefaults.standard.integer(forKey: PlacesSettingsKeys.rescanIntervalSeconds)
        return secs > 0 ? secs : PlacesSettingsKeys.defaultRescanIntervalSeconds
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
                peopleEngine.startScan(candidateRefKeys: await analysisOrderedRefKeys(dropboxStore: dropboxStore), allowSimulator: allowSim)
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
                    // 重い処理の中央ゲート（電源＋Wi-Fi＋ロック中）＋回線ポリシーを満たすときだけ
                    // 定期再スキャンする（操作中は動かさない方針・逆ジオコーディングは通信）。
                    guard !BackgroundYield.isAppInBackground,   // 背面の判断は処理枠側（上と同じ理由）
                          BackgroundYield.heavyWorkAllowed,
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
                    // ⚠️ 背面では判断しない。吊るされていたこのループは BGTask がプロセスを起こした
                    // 瞬間に「期限超過」で発火し、処理枠側の見送り判断（NightlyWorkPolicy）を
                    // 素通りして生成を始めていた（diagnostics-74: 枠の開始と同時に generate 25.6s・
                    // その間 顔スキャンが停止）。背面の生成は HeavyWorkScheduler だけが起こす。
                    guard !BackgroundYield.isAppInBackground else { continue }
                    await autoAlbumEngine.refreshIfNeeded()
                }
            }
            // BackupSettingsView のデバッグ表示用のバックアップ記録ロードは起動表示に不要なので、
            // 起動スパイクを避けるため大きく遅延する（設定を開く頃には間に合う）。
            .task {
                try? await Task.sleep(for: .seconds(5))
                await backupEngine.loadAlbums()
            }
            // PHAsset 索引（アルバム系ビューの高速オープン用）。起動スパイクを避けて遅延構築。
            .task {
                try? await Task.sleep(for: .seconds(3))
                assetIndex.buildIfNeeded()
            }
            // 共有セット概要の初期ロード（バッジの材料。DB 読みだけで軽い・通信なし）。
            .task { await shareEngine.refresh() }

            // 家族共有（ADR-112）: 起動から少し遅らせて (1) 家族サイドカーの取り込み、
            // (2) 共有セットの反映（保留分・自己修復）を行う。自動通信なので回線ポリシーに従う。
            .task {
                try? await Task.sleep(for: .seconds(25))
                guard NetworkStateMonitor.shared.networkAllowed() else { return }
                await shareImporter.runIfNeeded()
                if await hasShareSets() { await shareEngine.syncNow() }
            }
            // バックアップ完走後: waitingBackup だった共有アイテムを反映する。
            .onChange(of: backupEngine.isRunning) { wasRunning, running in
                guard wasRunning, !running else { return }
                Task {
                    guard NetworkStateMonitor.shared.networkAllowed() else { return }
                    if await hasShareSets() { await shareEngine.syncNow() }
                }
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
                    let folder = UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder) ?? BackupSettingsKeys.defaultDropboxFolder
                    Task {
                        // ADR-41: ルート（旧・フラット時代の既存分）＋この端末のフォルダを統合して読む。
                        await dropboxStore.loadBackupMetadata(
                            from: [folder, BackupEngine.deviceBackupRoot(for: folder)])
                        // 機種変更・再インストール後: 台帳が空なら metadata v2 の offloadedAt
                        // マーカーから台帳を再構築する（通常は台帳が正・ADR-39）。
                        if let metadata = dropboxStore.backupMetadata {
                            await backupEngine.rebuildOffloadLedgerIfEmpty(from: metadata)
                        }
                    }
                }
            }
    }

    /// 電源・回線ポリシーに応じて Dropbox 差分同期を起動/停止する。接続中のみ対象。
    /// 「電源OK かつ 回線OK」なら同期を開始、そうでなければ停止して通信・電池を抑える。
    /// 共有セットが 1 つでもあるか（無ければ反映のネットワーク往復を丸ごと省く）。
    /// ⚠️ 判定のためだけに `refresh()`（全セット集計）を呼ばない——件数だけ数える。
    private func hasShareSets() async -> Bool {
        await shareEngine.hasAnySet()
    }

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
