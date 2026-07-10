import AutoAlbumCore
import DropboxKit
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

/// クラウド path から Dropbox アイテムを組み立てる（表示名は lastPathComponent）。
/// `@Sendable` なアダプタ（CLIP 用画像ローダ等）からも呼ぶため nonisolated。
nonisolated func dropboxFileItem(path: String) -> DropboxFileItem {
    DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
}

/// カバー画像の共通リゾルバ：ローカル PHAsset があれば優先、無ければ Dropbox。
/// クラウド側はフル画像からカバー生成する（128px サムネ拡大だとカードで粗く見えるため）。
func loadCover(localID: String?, cloudPath: String?,
               dropboxStore: DropboxPhotoStore, maxPixel: CGFloat) async -> UIImage? {
    if let localID {
        return await loadLocalCover(localID, pixelSize: maxPixel)
    }
    if let cloudPath {
        return await dropboxStore.coverImage(for: dropboxFileItem(path: cloudPath), maxPixel: maxPixel)
    }
    return nil
}

/// `PhotoRef`（ローカル/クラウド統一キー）からのカバー解決（自動アルバムのカバー用）。
func loadCover(for ref: PhotoRef?, dropboxStore: DropboxPhotoStore, maxPixel: CGFloat) async -> UIImage? {
    switch ref {
    case .local(let id):   return await loadCover(localID: id, cloudPath: nil, dropboxStore: dropboxStore, maxPixel: maxPixel)
    case .cloud(let path): return await loadCover(localID: nil, cloudPath: path, dropboxStore: dropboxStore, maxPixel: maxPixel)
    case nil:              return nil
    }
}

// MARK: - Auto album card (時間＋場所・横カルーセル用の正方カード)

/// 自動アルバム（時間＋場所 / AI / フォルダ）用カード。レイアウトは `LibraryCard`（正方カバー＋
/// 下にテキスト）と共通で、ここではタイトル・日付・カバー（PhotoRef 解決）の組み立てだけを持つ。
/// 文字は画像に埋め込まず下にテキスト表示するため、明るい写真でも見切れず読める。
struct AutoAlbumCard: View {
    let album: AutoAlbumInfo
    let dropboxStore: DropboxPhotoStore

    var body: some View {
        LibraryCard(
            // アルバム名（訪問地）＋国名。画像に被せずテキスト表示。
            title: "\(album.placesLabel)\(album.country.map { ", \($0)" } ?? "")",
            // 日付は初日のみ（複数日でもシンプルに）。0 件は「該当なし」。
            // 無意味な日付（1980 等）は「日時不明」にする（変な日時にしない）。
            subtitle: album.photoCount == 0
                ? L("No matches")
                : (DisplayDate.meaningful(album.startDate).map(DisplayDate.ymd) ?? L("Date unknown")),
            placeholderSystemImage: "airplane",
            coverKey: album.id
        ) {
            await loadCover(for: album.coverPhotoRef, dropboxStore: dropboxStore,
                            maxPixel: LibraryCard.side * 2)
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
    private static let side: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatarImage(refKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 480)
                .frame(width: Self.side, height: Self.side)
                .clipShape(Circle())

            Text(person.displayName)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Self.side + 12)
    }
}
