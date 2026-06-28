import AutoAlbumCore
import DropboxKit
import LocalPhotoKit
import Photos
import PhotoSourceKit
import SwiftUI

// MARK: - Source row

/// 「Sources」セクションの行（アイコン付きタイトル＋サブタイトル＋シェブロン）。
struct SourceRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: 38, height: 38)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library row (アルバム / 場所 共通)

/// アルバム・場所セクションの共通行。カバー（48pt）＋タイトル＋件数＋シェブロン。
/// カバー読込は呼び出し側のクロージャに委譲する（ローカル PHAsset / Dropbox サムネイル）。
struct LibraryRow: View {
    let title: String
    let subtitle: String
    let placeholderSystemImage: String
    let coverKey: String
    let loadCover: () async -> UIImage?

    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 48, height: 48)
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: placeholderSystemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .task(id: coverKey) { cover = await loadCover() }
    }
}

/// 件数の表示文字列（"1 photo" / "N photos"）。
func photoCountText(_ count: Int) -> String {
    L("\(count) photos")
}

/// PHAsset.localIdentifier からカバーサムネイルを取得する（アルバム・場所・カード共通）。
func loadLocalCover(_ localIdentifier: String?, pixelSize: CGFloat = 96) async -> UIImage? {
    guard let localIdentifier else { return nil }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = result.firstObject else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    return await withCheckedContinuation { continuation in
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: pixelSize, height: pixelSize),
            contentMode: .aspectFill, options: options
        ) { image, _ in continuation.resume(returning: image) }
    }
}

// MARK: - Album row

struct AlbumRow: View {
    let album: LocalAlbumInfo
    var body: some View {
        LibraryRow(
            title: album.name,
            subtitle: photoCountText(album.photoCount),
            placeholderSystemImage: "photo.on.rectangle",
            coverKey: album.id
        ) {
            await loadLocalCover(album.coverLocalIdentifier)
        }
    }
}

// MARK: - Auto album card (時間＋場所・横カルーセル用の正方カード)

/// 正方形のカバー画像と、その下にテキストでアルバム名（訪問地）・期間・件数を表示するカード。
/// 文字は画像に埋め込まず下にテキスト表示するため、明るい写真でも見切れず読める。
/// すべてのアルバム種別（時間＋場所 / AI / フォルダ）で同一サイズに統一する。
struct AutoAlbumCard: View {
    let album: AutoAlbumInfo
    let dropboxStore: DropboxPhotoStore

    @State private var cover: UIImage?

    /// 正方カバーの一辺＝カード幅（全アルバム共通）。
    private static let side: CGFloat = 150

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
                    Image(systemName: "airplane")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // アルバム名（訪問地）＋国名。画像に被せずテキスト表示。
            Text("\(album.placesLabel)\(album.country.map { ", \($0)" } ?? "")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            // 日付は初日のみ（複数日でもシンプルに）。0 件は「該当なし」（取り込み済みだが一致なし）。
            Text(album.photoCount == 0 ? L("No matches") : DisplayDate.ymd(album.startDate))
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
        }
        .frame(width: Self.side, alignment: .leading)
        .task(id: album.id) {
            let pixel = Self.side * 2
            switch album.coverPhotoRef {
            case .local(let id):
                cover = await loadLocalCover(id, pixelSize: pixel)
            case .cloud(let path):
                let item = DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
                cover = await dropboxStore.thumbnail(for: item)
            case nil:
                cover = nil
            }
        }
    }
}

// MARK: - Place row

struct PlaceRow: View {
    let place: PlaceAlbumInfo
    let dropboxStore: DropboxPhotoStore
    var body: some View {
        LibraryRow(
            title: place.placeName,
            subtitle: photoCountText(place.photoCount),
            placeholderSystemImage: "mappin.and.ellipse",
            coverKey: place.id
        ) {
            // ローカルがあれば PHAsset、無ければ Dropbox サムネイル。
            if let localID = place.coverLocalID {
                return await loadLocalCover(localID)
            }
            if let path = place.coverCloudPath {
                let item = DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
                return await dropboxStore.thumbnail(for: item)
            }
            return nil
        }
    }
}
