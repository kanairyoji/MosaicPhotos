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
