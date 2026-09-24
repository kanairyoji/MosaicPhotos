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
nonisolated public func cloudImageRefKeys(items: [CloudPhotoRef]) -> [String] {
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

    /// 解析しないクラウドのパス接頭辞（小文字）。**自分の共有ルート**（`…/Share`・旧 `/MosaicShare`）。
    /// 共有コピーの原本と解析結果はバックアップ（または端末）にあるので、共有したからといって
    /// 顔・タグ・埋め込みをやり直さない（実フィードバック）。家族フォルダとして登録していて
    /// 表示に出る場合でも、解析はしない。
    @MainActor public static var excludedCloudPathPrefixes: [String] = []

    /// **端末に原本があるバックアップコピー**のクラウド refKey（"C-<path>"・パスは小文字で照合）。
    /// 表示の重複排除（`MergedPhotoStore`）と同じ規則。解析（顔・タグ・埋め込み）の候補から外す。
    ///
    /// ⚠️ なぜ要るか（実フィードバック「ピープルの分母がじわじわ上がる」）: バックアップフォルダは
    /// 同期対象（ADR-44）なので、背景アップロード（ADR-181）で上がった写真が**新しいクラウド写真**として
    /// 現れる。表示では隠れるが解析候補には入っていたため、端末で解析済みの写真をコピー側でもう一度
    /// 解析していた（顔が二重・分母が増え続ける）。
    @MainActor
    public static func hiddenBackupCopyRefKeys(cloudItems: [CloudPhotoRef],
                                               localRefKeys: [String]) async -> Set<String> {
        let index = await backupCopyIndexProvider?() ?? [:]
        let prefixes = excludedCloudPathPrefixes
        guard !index.isEmpty || !prefixes.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let localIDs = Set(localRefKeys.compactMap { PhotoRef.decode($0)?.localIdentifier })
            let hidden = BackupCopyHiding.hiddenPaths(
                backupCopies: index, localIdentifiers: localIDs)
            var keys = Set<String>()
            for item in cloudItems {
                let lower = item.path.lowercased()
                if hidden.contains(lower)
                    || prefixes.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) {
                    keys.insert(PhotoRef.cloud(item.path).encoded)
                }
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
    // ⚠️ **表示用の `items` を使わない**（ADR-224・実機ログ diagnostics-90）。
    // 候補に要るのはパスと撮影日だけなのに、`items` は全列の実体化を伴い、窓の開始で
    // フットプリントが 821MB まで跳ねていた（`cache.fetchItems 3306ms` の直後）。
    // 台帳から 2 列だけ引く。ついでに「items がまだ空なら読み込む」（ADR-85）も要らなくなる
    // ——台帳は画面を開いていなくても埋まっているので、起動直後でも取りこぼさない。
    // ⚠️ **内訳を測る**（実機ログ diagnostics-95）。窓の頭でフットプリントが 751MB → 1061MB へ
    // 跳ねる山がここにある（`driver.candidates.enumerated` の直後）。どの段が積んでいるのかは
    // 実測しないと分からない——推測で直す前に、段ごとの所要を残す（ADR-82 の「まず内訳を実測」）。
    // 重い一括なので札も立てる（ADR-122）。
    return await HeavyLoad.span("analysis.candidates") {
        let t0 = PerfTrace.nowNs()
        let cloudItems = await dropboxStore.cloudPhotoRefs()
        PerfTrace.logSpan("candidates.cloudRefs", ms: PerfTrace.msSince(t0),
                          detail: "n=\(cloudItems.count)")

        let t1 = PerfTrace.nowNs()
        let local = await localImageRefKeys()                       // 既に detached
        PerfTrace.logSpan("candidates.localRefs", ms: PerfTrace.msSince(t1), detail: "n=\(local.count)")

        let t2 = PerfTrace.nowNs()
        let favorites = await favoriteImageRefKeys(dropboxStore: dropboxStore)
        let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(cloudItems: cloudItems,
                                                                      localRefKeys: local)
        PerfTrace.logSpan("candidates.hidden", ms: PerfTrace.msSince(t2), detail: "n=\(hidden.count)")

        let t3 = PerfTrace.nowNs()
        let ordered = await Task.detached(priority: .utility) {
            var cloud = cloudImageRefKeys(items: cloudItems)        // ローカル(新→古)＋クラウド(新→古)
            if !hidden.isEmpty { cloud.removeAll { hidden.contains($0) } }
            return AnalysisOrder.ordered(local + cloud, favorites: favorites)
        }.value
        PerfTrace.logSpan("candidates.order", ms: PerfTrace.msSince(t3), detail: "n=\(ordered.count)")
        return (ordered, hidden)
    }
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
