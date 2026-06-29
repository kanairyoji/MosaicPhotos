#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit

extension DropboxPhotoStore: PhotoStore {
    public typealias Item = DropboxFileItem

    public var state: PhotoLoadState {
        guard case .connected = auth.connectionStatus else {
            return .needsSetup(
                message: "Not connected to Dropbox.",
                detail: "Connect via the Settings tab.",
                systemImage: "icloud.slash",
                action: .openAppSettings
            )
        }
        // ⚠️ accountId が nil の場合は state = .idle → onChange ループになる（過去に発生）。
        // needsSetup を返すことでループを断ち、ユーザーに再接続を促す。
        guard auth.credential?.accountId != nil else {
            return .needsSetup(
                message: "Dropbox account ID is missing.",
                detail: "Please disconnect and reconnect from the Settings tab.",
                systemImage: "person.crop.circle.badge.xmark",
                action: .openAppSettings
            )
        }
        let result: PhotoLoadState
        switch loadStatus {
        case .idle:    result = .idle
        case .loading: result = .loading
        case .loaded:
            // T2: キャッシュが空でも初回同期・差分取得が進行中なら「読み込み中」を維持し、
            // 取得完了前に "No photos" を一瞬出さない。
            if items.isEmpty {
                switch syncState {
                case .initialSync, .fetchingDelta: result = .loading
                default:                            result = .empty
                }
            } else {
                result = .loaded
            }
        case .failed(let message): result = .failed(message)
        }
        return result
    }

    /// キャッシュからアイテムを即時ロードする。メタ情報取得は DropboxSyncEngine が担う。
    /// syncState が .idle（同期未開始・終了済み）の場合は startSync() も呼ぶ。
    /// HomeView.onAppear が先に startSync() を呼んでいれば二重起動にはならない。
    ///
    /// すでにアイテムが表示済み（loaded）の場合は loadItems() をスキップする。
    /// loadItems() が items = cached を実行すると @Observable 通知が発火し、
    /// SwiftUI がサムネイルタスク実行中に PhotoGridView を再評価してセルの @State を失うことがある。
    public func start() async {
        if items.isEmpty || loadStatus != .loaded {
            await loadItems()
        }
        if case .idle = syncState {
            startSync()
        }
    }

    public func retry() async {
        await loadItems()
    }

    /// 元画像データ（DropboxCore 提供）から EXIF を抽出する。解析はバックグラウンドで実行。
    public func metadata(for item: DropboxFileItem) async -> PhotoExifInfo? {
        guard let data = await originalImageData(for: item) else { return nil }
        let name = item.name
        return await Task.detached(priority: .userInitiated) {
            PhotoExifInfo.parse(from: data, fileName: name)
        }.value
    }

    // hasMore / isLoadingMore / loadMore() は PhotoStore プロトコルのデフォルト実装を使用。
    // （false / false / no-op）
    // メタ情報はバックグラウンド同期エンジンが全件取得するため、オンデマンドページングは不要。
}
#endif
