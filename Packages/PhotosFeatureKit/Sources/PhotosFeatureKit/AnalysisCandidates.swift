#if canImport(UIKit)
import DropboxKit
import Foundation
import MosaicSupport
import PerceptionCore
import Photos

// MARK: - 解析候補の refKey（顔スキャン・タグ付けの入力）
//
// ⚠️ もとはアプリターゲットに居たが、中身は**写真ソースの統合そのもの**（端末 + Dropbox を
// 1 つの候補列にする）で、しかも 68,000 件のソートを含む＝性能規約（ADR-82/119）の対象。
// アプリにはパッケージテストが無く、回帰を固定できていなかったのでここへ移した。

/// 同期済みクラウド写真の refKey 一覧（"C-<path>"）。ピープルの顔スキャン候補（クラウド分）に使う。
/// クラウドはキャッシュ済みサムネ（thumbnailAPISize）で顔検出する（追加DL無し・大きい顔中心）。
/// **撮影日降順**（新しい順・日付なしは最後）＝新しい写真から先に解析する。
///
/// ⚠️ `nonisolated`：6.8 万件のソート＋map をメインで回さない（ADR-82）。呼び出し側が
/// `dropboxStore.items` のスナップショット（COW＝取得は安価）を渡し、この関数は off-main で走る。
nonisolated public func cloudImageRefKeys(items: [DropboxFileItem]) -> [String] {
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
public func analysisOrderedRefKeys(dropboxStore: DropboxPhotoStore) async -> [String] {
    await analysisCandidates(dropboxStore: dropboxStore).ordered
}

/// 解析候補の供給元（合成層が結線する）。
public enum AnalysisCandidates {
    /// バックアップ台帳（Dropbox パス小文字 → 端末の写真）。`MergedPhotoStore.backupCopyIndexProvider` と同じもの。
    /// ⚠️ 未結線なら**何も隠さない**（分からないものは隠さない＝`BackupCopyHiding` の方針）。
    @MainActor public static var backupCopyIndexProvider: (@Sendable () async -> [String: BackupCopyInfo])?

    /// **端末に原本があるバックアップコピー**のクラウド refKey（"C-<path>"・パスは小文字で照合）。
    /// 表示の重複排除（`MergedPhotoStore`）と同じ規則。解析（顔・タグ・埋め込み）の候補から外す。
    ///
    /// ⚠️ なぜ要るか（実フィードバック「ピープルの分母がじわじわ上がる」）: バックアップフォルダは
    /// 同期対象（ADR-44）なので、背景アップロード（ADR-181）で上がった写真が**新しいクラウド写真**として
    /// 現れる。表示では隠れるが解析候補には入っていたため、端末で解析済みの写真をコピー側でもう一度
    /// 解析していた（顔が二重・分母が増え続ける）。
    @MainActor
    public static func hiddenBackupCopyRefKeys(cloudItems: [DropboxFileItem], localRefKeys: [String]) async -> Set<String> {
        guard let provider = backupCopyIndexProvider else { return [] }
        let index = await provider()
        guard !index.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let localIDs = Set(localRefKeys.compactMap { PhotoRef.decode($0)?.localIdentifier })
            let hidden = BackupCopyHiding.hiddenPaths(
                backupPathToLocalID: index.compactMapValues(\.localIdentifier), localIdentifiers: localIDs)
            guard !hidden.isEmpty else { return [] }
            var keys = Set<String>()
            for item in cloudItems where hidden.contains(item.path.lowercased()) {
                keys.insert(PhotoRef.cloud(item.path).encoded)
            }
            return keys
        }.value
    }
}

/// 解析候補（処理順つき）と、候補から外した**バックアップコピー**（端末に原本あり）。
/// 外した分は顔台帳の掃除（`pruneMissingPhotos`）で「無くなった」扱いにしてよい。
@MainActor
public func analysisCandidates(dropboxStore: DropboxPhotoStore) async
    -> (ordered: [String], excludedBackupCopies: Set<String>) {
    // ⚠️ items は All Photos / Cloud を開くまで読み込まれない（ADR-85）。起動直後はこの関数の方が
    // 早く、空のまま候補を作ると**クラウド写真が丸ごと解析対象から漏れる**。実機ログ diag-33 で
    // candidates=6699（ローカルのみ）になり、2 秒後に 68,200 件がロードされていた。
    // `DropboxCloudPhotoProvider.cloudPhotos()` は同じ理由で既にこのガードを持っている＝揃える。
    if dropboxStore.items.isEmpty { await dropboxStore.loadItems() }
    let cloudItems = dropboxStore.items                             // MainActor 上のスナップショット（安価）
    let local = await localImageRefKeys()                           // 既に detached
    let favorites = await favoriteImageRefKeys(dropboxStore: dropboxStore)
    let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(cloudItems: cloudItems, localRefKeys: local)
    let ordered = await Task.detached(priority: .utility) {
        var cloud = cloudImageRefKeys(items: cloudItems)            // ローカル(新→古)＋クラウド(新→古)
        if !hidden.isEmpty { cloud.removeAll { hidden.contains($0) } }
        return AnalysisOrder.ordered(local + cloud, favorites: favorites)
    }.value
    return (ordered, hidden)
}

/// 端末写真（画像）の refKey 一覧（"L-<localIdentifier>"）。ピープルの顔スキャン候補に使う。
/// ⚠️ アプリ層の top-level 関数はデフォルト MainActor になるため、全件列挙（数万件）は
/// `Task.detached` で**メインスレッド外**へ逃がす（起動直後のホーム描画を固めない）。
public func localImageRefKeys() async -> [String] {
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
public func localImagePhotoCount() async -> Int {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: opts).count
    }.value
}

/// お気に入りの端末写真（画像）の refKey 集合（"L-…"）。列挙はメインスレッド外。
public func localFavoriteImageRefKeys() async -> Set<String> {
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
public func favoriteImageRefKeys(dropboxStore: DropboxPhotoStore) async -> Set<String> {
    var keys = await localFavoriteImageRefKeys()
    for path in dropboxStore.favoriteCloudPaths { keys.insert(PhotoRef.cloud(path).encoded) }
    return keys
}
#endif
