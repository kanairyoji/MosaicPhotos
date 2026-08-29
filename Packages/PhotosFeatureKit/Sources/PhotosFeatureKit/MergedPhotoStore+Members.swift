#if canImport(UIKit)
import DropboxKit
import LocalPhotoKit

extension MergedPhotoStore {

    /// メンバー限定ストアが共通で使う「バックアップ副本の索引」（パス → localIdentifier）。
    ///
    /// ⚠️ **アルバムを開く画面でも副本を隠す**（実フィードバック: 「グループアルバムが時系列で
    /// 並んでいない／バックアップを新しい写真と認識している？」）。ホームの一覧（All Photos）は
    /// diagnostics-57/58 で対処済みだったが、人物・グループ・場所・アルバムの**メンバー限定
    /// ストアには渡していなかった**。そのため同じ写真が「端末の原本」と「バックアップ副本」の
    /// 2 枚として並び、しかも副本の撮影日は Dropbox の `time_taken` が無いと**アップロード時刻**に
    /// 落ちるので、古い写真が列の先頭（最新）に現れる＝並びが壊れて見える。
    /// Composition Root（アプリ）が起動時に設定する。未設定なら従来どおり全部出す。
    @MainActor
    public static var defaultBackupCopyIndexProvider: (@Sendable () async -> [String: String])?
    /// メンバー限定ストアの共通生成。ローカル ID は索引（`LocalAssetIndex`）から即解決し、
    /// 未構築なら `localIdentifiers` で遅延取得にフォールバック。クラウドは path フィルタ。
    /// PersonAlbum / AutoAlbumPhotos / DeviceAlbumPhotos / PlacePhotos の 4 ビューが同型の定型を
    /// 各 init に複写していたのを 1 箇所へ集約する。
    @MainActor
    public static func forMembers(localIDs: [String], cloudPaths: [String],
                           dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex) -> MergedPhotoStore {
        let localStore = assetIndex.assets(for: localIDs).map { LocalPhotoStore(preloadedAssets: $0) }
            ?? LocalPhotoStore(localIdentifiers: localIDs)
        let store = MergedPhotoStore(dropboxStore: dropboxStore, localStore: localStore,
                                     cloudPathFilter: Set(cloudPaths))
        store.backupCopyIndexProvider = defaultBackupCopyIndexProvider
        return store
    }
}
#endif
