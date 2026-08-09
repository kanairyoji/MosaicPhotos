import AutoAlbumCore
import MobileCLIPKit
import DropboxKit
import MosaicSupport
import Photos
import UIKit

// MARK: - Candidate refKeys

/// 同期済みクラウド写真の refKey 一覧（"C-<path>"）。ピープルの顔スキャン候補（クラウド分）に使う。
/// クラウドはキャッシュ済みサムネ（thumbnailAPISize）で顔検出する（追加DL無し・大きい顔中心）。
/// **撮影日降順**（新しい順・日付なしは最後）＝新しい写真から先に解析する。
///
/// ⚠️ `nonisolated`：6.8 万件のソート＋map をメインで回さない（ADR-82）。呼び出し側が
/// `dropboxStore.items` のスナップショット（COW＝取得は安価）を渡し、この関数は off-main で走る。
nonisolated func cloudImageRefKeys(items: [DropboxFileItem]) -> [String] {
    items
        .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
        .map { PhotoRef.cloud($0.path).encoded }
}

/// 解析（顔スキャン等）の**処理順**に並べた候補: お気に入り（ローカル→クラウド）→ その他
/// （ローカル→クラウド）、各群は新→古（`AnalysisOrder`）。お気に入りから先に People へ反映される。
///
/// ⚠️ 並べ替えは**すべて off-main**（ADR-82）。以前は `cloudImageRefKeys`（6.8 万件のソート）と
/// `AnalysisOrder.ordered`（8.6 万件のソート・比較ごとに接頭辞判定と Set 参照）を @MainActor で
/// 実行しており、**起動のたびにメインが 2.7〜3.2 秒止まっていた**（実機ログ diagnostics-32）。
/// 夜間 BGTask でも同じ経路を通るため、背面での長い停止の一因でもあった。
@MainActor
func analysisOrderedRefKeys(dropboxStore: DropboxPhotoStore) async -> [String] {
    // ⚠️ items は All Photos / Cloud を開くまで読み込まれない（ADR-85）。起動直後はこの関数の方が
    // 早く、空のまま候補を作ると**クラウド写真が丸ごと解析対象から漏れる**。実機ログ diag-33 で
    // candidates=6699（ローカルのみ）になり、2 秒後に 68,200 件がロードされていた。
    // `DropboxCloudPhotoProvider.cloudPhotos()` は同じ理由で既にこのガードを持っている＝揃える。
    if dropboxStore.items.isEmpty { await dropboxStore.loadItems() }
    let cloudItems = dropboxStore.items                             // MainActor 上のスナップショット（安価）
    let local = await localImageRefKeys()                           // 既に detached
    let favorites = await favoriteImageRefKeys(dropboxStore: dropboxStore)
    return await Task.detached(priority: .utility) {
        let cloud = cloudImageRefKeys(items: cloudItems)            // ローカル(新→古)＋クラウド(新→古)
        return AnalysisOrder.ordered(local + cloud, favorites: favorites)
    }.value
}

/// 端末写真（画像）の refKey 一覧（"L-<localIdentifier>"）。ピープルの顔スキャン候補に使う。
/// ⚠️ アプリ層の top-level 関数はデフォルト MainActor になるため、全件列挙（数万件）は
/// `Task.detached` で**メインスレッド外**へ逃がす（起動直後のホーム描画を固めない）。
func localImageRefKeys() async -> [String] {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        // 顔スキャンはスクリーンショットを対象外にする（(a)・顔がまず写らないのに 1 枚 ~1s かかり
        // backlog を膨らませる）。この候補パスは顔スキャン専用（CLIP 埋め込み/タグは別の候補経路）
        // なので、除外しても検索/タグ付けには影響しない。除外分は「スキャン済み」記録も作らない
        // ＝候補に上がらないだけ（将来スクショに人物が必要になれば設定で戻せる）。
        opts.predicate = NSPredicate(
            format: "mediaType == %d && (mediaSubtypes & %d) == 0",
            PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
        // 新しい写真から先に解析する（全解析パス共通の方針＝撮りたての写真が最速で反映される）。
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: opts)
        var keys: [String] = []
        keys.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            keys.append(PhotoRef.local(asset.localIdentifier).encoded)
        }
        return keys
    }.value
}

/// 端末写真（画像）の総数。顔スキャンの進捗の分母（AI 解析の状況画面）に使う。
/// `fetchAssets(...).count` は遅延評価なので列挙より軽い。取得はメインスレッド外。
func localImagePhotoCount() async -> Int {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: opts).count
    }.value
}

/// お気に入りの端末写真（画像）の refKey 集合（"L-…"）。列挙はメインスレッド外。
func localFavoriteImageRefKeys() async -> Set<String> {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "favorite == YES && mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: opts)
        var keys = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            keys.insert(PhotoRef.local(asset.localIdentifier).encoded)
        }
        return keys
    }.value
}

/// お気に入りの refKey 集合（ローカル "L-…" ＋ クラウド "C-…"）。
/// ローカルは PHAsset.isFavorite、クラウドはアプリ側お気に入り（`DropboxPhotoStore.favoriteCloudPaths`）。
/// 代表写真の自動選択・解析の処理順（お気に入り優先）に使う。
@MainActor
func favoriteImageRefKeys(dropboxStore: DropboxPhotoStore) async -> Set<String> {
    var keys = await localFavoriteImageRefKeys()
    for path in dropboxStore.favoriteCloudPaths { keys.insert(PhotoRef.cloud(path).encoded) }
    return keys
}

// MARK: - Cluster members → local identifiers

/// クラスタのメンバー refKey をローカル localIdentifier 配列へ。
func localIdentifiers(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.localIdentifier }
}

/// クラスタのメンバー refKey をクラウド（Dropbox）path 配列へ。人物アルバムのクラウドメンバー表示用。
func cloudPaths(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.cloudPath }
}

// MARK: - Face avatar

/// 代表顔の写真からアバター（顔の切り抜き）を作る。`box` は Vision の正規化矩形（原点左下）。
func loadFaceAvatar(coverRefKey: String?, box: CGRect?, maxPixel: CGFloat = 600) async -> UIImage? {
    guard let coverRefKey, let box, let ref = PhotoRef.decode(coverRefKey) else { return nil }
    let source: CGImage?
    if let localID = ref.localIdentifier {
        source = await requestAspectCGImage(localID, maxPixel: maxPixel)
    } else if let path = ref.cloudPath {
        // クラウド顔: Dropbox のキャッシュ済み 128px サムネから切り抜く（低解像度アバター・追加DL無し）。
        source = await HeavyWorkScheduler.stores?.dropboxStore.thumbnail(for: dropboxFileItem(path: path))
            .flatMap(orientationNormalizedCGImage)   // EXIF 回転を正規化（検出座標と同じ向きに）
    } else {
        source = nil
    }
    guard let cg = source else { return nil }
    let width = CGFloat(cg.width), height = CGFloat(cg.height)
    let margin: CGFloat = 0.35
    var b = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    if b.isNull { b = box }
    let pixel = CGRect(
        x: b.minX * width,
        y: (1 - b.minY - b.height) * height,   // Vision(下原点) → CGImage(上原点)
        width: b.width * width,
        height: b.height * height)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard pixel.width >= 1, pixel.height >= 1, let cropped = cg.cropping(to: pixel) else { return nil }
    return UIImage(cgImage: cropped)
}

/// アスペクトを保った端末画像を取得する（顔矩形を重ねて表示するため正方クロップしない）。refKey 版。
func loadLocalAspectImage(refKey: String, maxPixel: CGFloat = 1000) async -> UIImage? {
    guard let localID = PhotoRef.decode(refKey)?.localIdentifier,
          let cg = await requestAspectCGImage(localID, maxPixel: maxPixel) else { return nil }
    return UIImage(cgImage: cg)
}

/// アスペクトを保った**向き正規化済み** CGImage を取得する（顔矩形を正しくマッピングするため
/// 正方クロップしない）。実体は共通ローダ `PHAssetImageLoader`（顔検出の入力と同一経路）。
private func requestAspectCGImage(_ localIdentifier: String, maxPixel: CGFloat) async -> CGImage? {
    await PHAssetImageLoader.cgImage(localIdentifier: localIdentifier, maxPixel: maxPixel,
                                     contentMode: .aspectFit, allowsNetwork: true)
}
