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
    // ⚠️ .opportunistic は「劣化版→確定版」と結果ハンドラを複数回呼ぶため、withCheckedContinuation を
    //    二重 resume して実機でクラッシュしていた（SWIFT TASK CONTINUATION MISUSE）。確定版を 1 回だけ
    //    返す .highQualityFormat にし、さらに resume を一度きりに保証する（ロックで二重 resume を根絶）。
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    let lock = NSLock()
    var didResume = false
    return await withCheckedContinuation { continuation in
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: pixelSize, height: pixelSize),
            contentMode: .aspectFill, options: options
        ) { image, _ in
            lock.lock(); defer { lock.unlock() }
            guard !didResume else { return }   // 2 回目以降のコールバックは無視（二重 resume 防止）
            didResume = true
            continuation.resume(returning: image)
        }
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
            // 日付は初日のみ（複数日でもシンプルに）。0 件は「該当なし」。
            // 無意味な日付（1980 等）は「日時不明」にする（変な日時にしない）。
            Text(album.photoCount == 0
                 ? L("No matches")
                 : (DisplayDate.meaningful(album.startDate).map(DisplayDate.ymd) ?? L("Date unknown")))
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
                // タイトル写真はフル画像から生成する（128px サムネ拡大だとカードで粗く見えるため）。
                let item = DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
                cover = await dropboxStore.coverImage(for: item, maxPixel: pixel)
            case nil:
                cover = nil
            }
        }
    }
}

// MARK: - People carousel (端末の人物・円形アバター)

/// ピープル（顔クラスタ）を円形アバターの横スクロールで表示する（Time & Place 直下）。
/// タップで写真一覧へ。長押しで名前を付け直せる（`onRename`）。
struct PeopleCarousel: View {
    let people: [PersonInfo]
    let onSelect: (PersonInfo) -> Void
    let onLongPress: (PersonInfo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(people) { person in
                    // Button＋contextMenu は「横スクロール×List 行」でヒット領域が行全体に化ける
                    // （バー全体がハイライトされ、常に先頭カードのメニューを拾う）ため、各カードに
                    // 直接タップ／長押しジェスチャを付けて確実にそのカードを対象にする。
                    // タップ＝写真一覧、長押し＝メニュー（名前変更／代表写真の変更）。
                    PersonCard(person: person)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(person) }
                        .onLongPressGesture(minimumDuration: 0.4) { onLongPress(person) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets())
    }
}

/// 円形アバター（代表顔の切り抜き）＋名前（未設定は "Person N"）＋枚数。
private struct PersonCard: View {
    let person: PersonInfo
    @State private var avatar: UIImage?
    private static let side: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(uiColor: .secondarySystemBackground))
                if let avatar {
                    Image(uiImage: avatar).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(Circle())

            Text(person.displayName)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Self.side + 12)
        // 代表写真(cover)を変えたら再読込されるよう、id に coverRefKey を含める
        //（clusterID だけだと cover 変更で再読込されずトップの写真が更新されない）。
        .task(id: person.coverRefKey ?? "\(person.id)") {
            avatar = await loadFaceAvatar(coverRefKey: person.coverRefKey,
                                          box: person.coverBoundingBox,
                                          maxPixel: 480)
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
