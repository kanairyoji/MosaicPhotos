import AutoAlbumCore
import DropboxKit
import SwiftUI

/// 自動アルバムの横スクロールカルーセル（Time & Place / AI / フォルダ で共通）。
/// `onEdit` / `onDelete` を渡したときだけ長押しメニュー（AI アルバム用）を表示する。
struct AlbumCarousel: View {
    let albums: [AutoAlbumInfo]
    let dropboxStore: DropboxPhotoStore
    let onSelect: (AutoAlbumInfo) -> Void
    var onEdit: ((AutoAlbumInfo) -> Void)?
    var onDelete: ((AutoAlbumInfo) -> Void)?

    init(albums: [AutoAlbumInfo], dropboxStore: DropboxPhotoStore,
         onSelect: @escaping (AutoAlbumInfo) -> Void,
         onEdit: ((AutoAlbumInfo) -> Void)? = nil,
         onDelete: ((AutoAlbumInfo) -> Void)? = nil) {
        self.albums = albums
        self.dropboxStore = dropboxStore
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    private var hasMenu: Bool { onEdit != nil || onDelete != nil }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    // カード本体（タップで開く）＋ 右上の「…」メニュー（編集/削除）。
                    // List の行に入った横スクロール carousel では contextMenu（長押し）が
                    // 行全体に効いて個々のカードに束縛できないため、明示的な per-card Menu を使う。
                    Button { onSelect(album) } label: {
                        AutoAlbumCard(album: album, dropboxStore: dropboxStore)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if hasMenu { menuButton(for: album) }
                    }
                    .id(album.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
        .listRowInsets(EdgeInsets())
    }

    /// カードごとの「…」メニュー。`Menu` は per-card のタップ対象なので、その album に確実に束縛される。
    private func menuButton(for album: AutoAlbumInfo) -> some View {
        Menu {
            if let onEdit {
                Button { onEdit(album) } label: { Label("Edit Album", systemImage: "pencil") }
            }
            if let onDelete {
                Button(role: .destructive) { onDelete(album) } label: {
                    Label("Delete Album", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .padding(6)
        }
        .accessibilityLabel("Album options")
    }
}

// MARK: - Library carousel (端末アルバム・場所用の汎用横カルーセル)

/// 端末アルバム・場所アルバムを、自動アルバム（AutoAlbumCard）と同じ見た目・サイズの
/// 横スクロールカルーセルで表示する汎用ビュー。カバーの取得はクロージャで注入する。
struct LibraryCarousel<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    let subtitle: (Item) -> String
    let placeholderSystemImage: String
    let cover: (Item) async -> UIImage?
    let onSelect: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    Button { onSelect(item) } label: {
                        LibraryCard(title: title(item), subtitle: subtitle(item),
                                    placeholderSystemImage: placeholderSystemImage,
                                    coverKey: "\(item.id)") { await cover(item) }
                    }
                    .buttonStyle(.plain)
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
        .listRowInsets(EdgeInsets())
    }
}

/// 正方カバー＋下にタイトル/サブタイトルの共通カード。カバー取得はクロージャで注入する。
/// 全アルバム種別（端末アルバム / 場所 / 時間＋場所 / AI / フォルダ）で同一レイアウト・サイズに統一する
/// （自動アルバムは `AutoAlbumCard` がこのカードに組み立てを載せる薄いラッパー）。
struct LibraryCard: View {
    let title: String
    let subtitle: String
    let placeholderSystemImage: String
    let coverKey: String
    let loadCover: () async -> UIImage?

    @State private var cover: UIImage?
    /// 正方カバーの一辺＝カード幅（全アルバム共通）。
    static let side: CGFloat = 150

    // `@State` が private のため memberwise init も private になる。別ファイル（AutoAlbumCard）
    // から使えるよう明示 init を持つ。
    init(title: String, subtitle: String, placeholderSystemImage: String,
         coverKey: String, loadCover: @escaping () async -> UIImage?) {
        self.title = title
        self.subtitle = subtitle
        self.placeholderSystemImage = placeholderSystemImage
        self.coverKey = coverKey
        self.loadCover = loadCover
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: placeholderSystemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
        }
        .frame(width: Self.side, alignment: .leading)
        .task(id: coverKey) {
            cover = await loadCover()
        }
    }
}
