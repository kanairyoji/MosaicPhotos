import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Home sections
//
// HomeView の `List` を構成する各セクションのビルダ。HomeView.swift は state・init（依存配線）と
// body（ルーティング）に専念し、セクションの見た目はここに集約する。
// extension が別ファイルから HomeView の格納プロパティへアクセスするため、参照先は internal にしている。

extension HomeView {

    // MARK: Sources section

    @ViewBuilder
    var sourceSection: some View {
        Section {
            SourceRow(
                systemImage: "photo.stack",
                tint: .indigo,
                title: L("All Photos"),
                subtitle: L("Device + Dropbox combined")
            ) {
                destination = .source(.all)
            }
            .listRowInsets(Self.sourceRowInsets)

            SourceRow(
                systemImage: "iphone",
                tint: .blue,
                title: L("On-Device Photos"),
                subtitle: L("Photos stored on this device")
            ) {
                destination = .source(.local)
            }
            .listRowInsets(Self.sourceRowInsets)

            SourceRow(
                systemImage: cloudIcon,
                tint: .cyan,
                title: L("Cloud"),
                subtitle: cloudSubtitle
            ) {
                destination = .source(.cloud)
            }
            .listRowInsets(Self.sourceRowInsets)
        } header: {
            Text("Sources")
        }
    }

    /// ソース 3 行の行インセット。`.insetGrouped` 既定（上下 ~11pt）は 3 行並ぶと間延びするため、
    /// 上下を詰めて 1 かたまりに見せる。
    private static var sourceRowInsets: EdgeInsets {
        EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
    }

    // MARK: Device albums section

    @ViewBuilder
    var albumsSection: some View {
        Section {
            if !albumScanner.isLoaded {
                // キャッシュロード / スキャン完了前
                LoadingRow("Loading albums…")
            } else if albumScanner.albums.isEmpty {
                Label(
                    "No user-created albums found.",
                    systemImage: "rectangle.stack"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                // 他のアルバム（Time & Place / AI / フォルダ）と同じ横スクロールカルーセルで表示する。
                LibraryCarousel(
                    items: albumScanner.albums,
                    title: { $0.name },
                    subtitle: { photoCountText($0.photoCount) },
                    placeholderSystemImage: "photo.on.rectangle",
                    cover: { album in
                        await loadLocalCover(album.coverLocalIdentifier, pixelSize: 300)
                    },
                    onSelect: { destination = .localAlbum($0) })
            }
        } header: {
            sectionHeader("Device Albums", isBusy: albumScanner.isScanning,
                          onAction: albumScanner.isLoaded ? { Task { await albumScanner.scan() } } : nil)
        }
    }

    // MARK: Places section

    @ViewBuilder
    var placesSection: some View {
        Section {
            if !placeScanner.isLoaded {
                LoadingRow("Loading places…")
            } else if placeScanner.places.isEmpty {
                Label("No photos with location found.", systemImage: "mappin.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 他のアルバムと同じ横スクロールカルーセルで表示する。
                LibraryCarousel(
                    items: placeScanner.places,
                    title: { $0.placeName },
                    subtitle: { photoCountText($0.photoCount) },
                    placeholderSystemImage: "mappin.and.ellipse",
                    cover: { [dropboxStore] place in
                        // ローカルがあれば PHAsset、無ければ Dropbox（フル画像からカバー生成）。
                        await loadCover(localID: place.coverLocalID, cloudPath: place.coverCloudPath,
                                        dropboxStore: dropboxStore, maxPixel: 300)
                    },
                    onSelect: { destination = .place($0) })
            }
        } header: {
            sectionHeader("Places", isBusy: placeScanner.isScanning,
                          onAction: placeScanner.isLoaded
                              ? { Task { await placeScanner.scan(dropboxItems: dropboxStore.items) } }
                              : nil)
        }
    }

    // MARK: Auto albums section (時間＋場所)

    @ViewBuilder
    var autoAlbumsSection: some View {
        Section {
            if !autoAlbumEngine.isLoaded {
                LoadingRow("Loading albums…")
            } else if autoAlbumEngine.albums.isEmpty {
                Label("No trip albums yet.", systemImage: "airplane")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AlbumCarousel(albums: autoAlbumEngine.albums, dropboxStore: dropboxStore) {
                    destination = .autoAlbum($0)
                }
            }
        } header: {
            sectionHeader("Time & Place", isBusy: autoAlbumEngine.isGenerating,
                          onAction: autoAlbumEngine.isLoaded ? { Task { await autoAlbumEngine.generate() } } : nil)
        }
    }

    // MARK: People section (端末写真の顔クラスタ＝オンデバイス Vision+CLIP 顔モデル)

    /// 端末写真を顔検出＋クラスタリングして得た「人物」を、円形アバターの横スクロールで表示する。
    /// 表示は Time & Place の直下。タップでその人物の写真一覧へ。顔モデル未同梱なら非表示。
    @ViewBuilder
    var peopleSection: some View {
        if peopleEngine.isFaceModelAvailable {
            Section {
                if peopleEngine.prominentPeople.isEmpty && peopleEngine.people.isEmpty {
                    if peopleEngine.isScanning {
                        LoadingRow("Finding people…")
                    } else {
                        Label("No people found yet.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // トップの列は「よく写っている人」だけ（5枚以上）。断片は「すべて表示」へ。
                    PeopleCarousel(
                        people: peopleEngine.prominentPeople,
                        groups: peopleEngine.peopleGroups,
                        totalPeople: peopleEngine.people.count,
                        onSelect: { destination = .person($0) },
                        onLongPress: { personActions = $0 },
                        onSelectGroup: { destination = .peopleGroup($0) },
                        onLongPressGroup: { peopleGroupActions = $0 },
                        onSeeAll: { showingAllPeople = true })
                }
            } header: {
                // レビュー（「同じ人物？」確認カード）: 答えるほど認識が良くなる（ADR-46）。
                // ⚠️ 小さな ✓ アイコンでは存在に気付かれない（実フィードバック）ため、
                // テキスト付きの色付きカプセルボタンにする。
                // ⚠️ スキャン中も Review を出す。以前は `if isScanning { spinner } else if …` と
                // **排他**にしていたため、顔スキャンが何時間も続くトリクル処理である以上
                // ボタンがほとんど画面に出ず、ユーザーからは「確認がめったに出てこない・
                // クルクルばかり」に見えていた（実フィードバック）。レビューは台帳を読むだけで
                // スキャンと競合しないので、いつでも開けてよい。進行中の表示は併記する。
                HStack(spacing: 8) {
                    // ⚠️ ボタンが増えた分、タイトルが幅圧縮で縦書き状に潰れないよう 1 行固定。
                    Text("People")
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    if peopleEngine.isScanning {
                        BusySpinner().scaleEffect(0.7)   // ADR-96
                    }
                    // 分裂が多いライブラリでは 1 対 1 の確認では追いつかないので、
                    // 「まとめて確認」を先に出す（ADR-68）。文言つきカプセルは「確認」だけに絞り、
                    // こちらはアイコンのみ（3 つ並ぶとヘッダー幅が尽きてタイトルが潰れる・実フィードバック）。
                    if peopleEngine.people.count >= PeopleCarousel.carouselLimit {
                        Button {
                            showingBatchReview = true
                        } label: {
                            Image(systemName: "person.2.badge.plus")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .accessibilityLabel(L("Merge"))
                        .buttonStyle(.plain)
                    }
                    if peopleEngine.people.count >= 1 {
                        Button {
                            showingFaceReview = true
                        } label: {
                            Label(L("Review"), systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    // ピープルグループ（家族・組織など複数人の束）を作る。2 人以上いるときだけ。
                    // アイコンのみ（幅対策・上と同じ）。※ L("Group") は束ね機能の訳「束ねる」と
                    // 衝突するため使わない。
                    if peopleEngine.people.count >= 2 {
                        Button {
                            showingGroupCreation = true
                        } label: {
                            Image(systemName: "person.3")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .accessibilityLabel(L("New People Group"))
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Cloud shared section (受け取った共有アルバム・ADR-112)

    /// クラウド共有で受け取ったアルバム（家族フォルダ配下の共有セット）。
    /// 受け取りが 1 つも無ければセクションごと非表示。
    @ViewBuilder
    var cloudSharedSection: some View {
        if !sharedAlbums.isEmpty {
            Section {
                SharedAlbumsCarousel(albums: sharedAlbums, dropboxStore: dropboxStore,
                                     onSelect: { destination = .sharedAlbum($0) })
            } header: {
                HStack {
                    Label(L("Cloud Sharing"), systemImage: "icloud.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                    Spacer()
                }
            }
        }
    }

    // MARK: AI albums section (自然文・オンデバイス)

    /// 自然文で作る AI アルバム。ヘッダーの「＋」でコンポーザーを開く。
    /// 表示は Time & Place と同じ横スクロールカルーセル。長押しで削除。
    @ViewBuilder
    var aiAlbumsSection: some View {
        Section {
            if autoAlbumEngine.aiAlbums.isEmpty {
                Button {
                    aiComposer = .create
                } label: {
                    Label("Describe an album — e.g. “Okinawa trips in recent years”.", systemImage: "sparkles")
                        .font(.callout)
                }
            } else {
                AlbumCarousel(
                    albums: autoAlbumEngine.aiAlbums, dropboxStore: dropboxStore,
                    onSelect: { destination = .autoAlbum($0) },
                    onEdit: { aiComposer = .edit($0) },
                    onDelete: { album in Task { await autoAlbumEngine.deleteAIAlbum(id: album.id) } })
            }
        } header: {
            sectionHeader("AI Albums", isBusy: autoAlbumEngine.isMakingAIAlbum, actionIcon: "plus",
                          onAction: { aiComposer = .create })
        }
    }

    // MARK: Path albums section (Dropbox フォルダ名から推測)

    /// フォルダ名アルバム（任意機能）。設定 ON のときセクションを表示する。
    /// 0 件でも空状態のヒントを出して「どこに表示されるか」を分かるようにする。
    /// 表示方法は Time & Place と同じ横スクロールカルーセル。
    @ViewBuilder
    var pathAlbumsSection: some View {
        if pathAlbumsEnabled {
            Section {
                if !autoAlbumEngine.isLoaded {
                    LoadingRow("Loading albums…")
                } else if autoAlbumEngine.pathAlbums.isEmpty {
                    Label("No folder albums yet. Add rules in Settings → Albums → Folder Albums, then regenerate.",
                          systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    AlbumCarousel(albums: autoAlbumEngine.pathAlbums, dropboxStore: dropboxStore) {
                        destination = .autoAlbum($0)
                    }
                }
            } header: {
                // フォルダ名アルバムだけの軽量再生成（地名解決なし・バックグラウンド）。
            // 実体は Dropbox のパス（フォルダ名）から作るため「クラウドアルバム」と表示する。
                sectionHeader("Cloud Albums", isBusy: autoAlbumEngine.isGeneratingPath,
                              onAction: { Task { await autoAlbumEngine.generatePathAlbums() } })
            }
        }
    }

    // MARK: Cloud icon / subtitle

    var cloudIcon: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:               return "cloud.fill"
        case .authenticating:          return "arrow.trianglehead.2.clockwise"
        case .notConnected, .error:    return "icloud.slash"
        }
    }

    var cloudSubtitle: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:      return L("Dropbox · Connected")
        case .authenticating: return L("Dropbox · Connecting...")
        case .notConnected:   return L("Dropbox · Not connected")
        case .error:          return L("Dropbox · Error")
        }
    }
}

// MARK: - Section building blocks（各セクション共通の部品）

/// セクションヘッダ共通部品：タイトル＋右端に「実行中スピナー or アクションボタン」。
/// `isBusy` 中は mini スピナー、そうでなければ `onAction`（省略可）のアイコンボタンを出す。
@ViewBuilder
private func sectionHeader(_ title: LocalizedStringKey, isBusy: Bool,
                           actionIcon: String = "arrow.clockwise",
                           onAction: (() -> Void)? = nil) -> some View {
    HStack {
        Text(title)
        Spacer()
        if isBusy {
            // ⚠️ 標準の `ProgressView` ではなく `BusySpinner`（ADR-96）。起動直後は
            //    アルバム生成・場所走査・顔スキャン開始・68,200 件の読み込みが重なり、
            //    メインが 1 秒級で止まることがある。フレーム駆動のスピナーだと一緒に止まり
            //    「固まった」ように見えるが、CAAnimation ならその間も回り続ける。
            BusySpinner().scaleEffect(0.7)
        } else if let onAction {
            Button(action: onAction) {
                Image(systemName: actionIcon).font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

/// セクションのロード中に出す行（小スピナー＋説明文）。
private struct LoadingRow: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            BusySpinner().scaleEffect(0.85)   // メインが止まっても回り続ける（ADR-96）
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Active source

enum ActiveSource: String, Identifiable {
    case all, local, cloud
    var id: String { rawValue }
}

// MARK: - Full-screen destination

/// ホームからフルスクリーン表示する対象。ソース（All/On-Device/Cloud）・端末アルバム・場所・
/// 自動アルバムを **単一の** `.fullScreenCover(item:)` で扱うための統合 enum。
/// 4 つの `.fullScreenCover` を併用すると提示競合で別アルバムの中身が表示される不具合があったため、
/// 1 つに集約する（`AIComposerTarget` で `.sheet` に適用したのと同じ対策）。
enum HomeDestination: Identifiable {
    case source(ActiveSource)
    case localAlbum(LocalAlbumInfo)
    case person(PersonInfo)
    case peopleGroup(PeopleGroupInfo)
    case sharedAlbum(SharedAlbumDiscovery.Album)
    case place(PlaceAlbumInfo)
    case autoAlbum(AutoAlbumInfo)

    var id: String {
        switch self {
        case .source(let source): return "source-\(source.id)"
        case .localAlbum(let album): return "album-\(album.id)"
        case .person(let person): return "person-\(person.id)"
        case .peopleGroup(let group): return "pgroup-\(group.id)"
        case .sharedAlbum(let album): return "shared-\(album.id)"
        case .place(let place): return "place-\(place.id)"
        case .autoAlbum(let album): return "auto-\(album.id)"
        }
    }
}

// MARK: - AI composer target

/// AI アルバムシートの対象。新規作成と既存編集を1つの `.sheet(item:)` で扱う。
enum AIComposerTarget: Identifiable {
    case create
    case edit(AutoAlbumInfo)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let album): return album.id
        }
    }
}
