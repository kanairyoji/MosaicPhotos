#if canImport(UIKit)
import CoreLocation
import DropboxKit
import LocalPhotoKit
import Observation
import PhotoSourceKit
import UIKit

// MARK: - Merged photo store

/// ローカル写真（LocalPhotoStore）と Dropbox（DropboxPhotoStore）を統合して表示するストア。
///
/// - `DropboxPhotoStore` は HomeView が所有し、共有 NSCache・SyncEngine を維持したまま注入される。
///   MergedPhotoStore は別インスタンスを生成しない。
/// - `LocalPhotoStore` はこのストアが内部で保有する。
/// - `items` は computed property。`localStore.items` と `dropboxStore.items` にアクセスするため、
///   どちらのストアが更新されても SwiftUI が自動的に再描画する（Observable 連鎖追跡）。
@MainActor
@Observable
public final class MergedPhotoStore {

    // @ObservationIgnored: 参照自体は変化しないため追跡不要。
    // ただし各ストアのプロパティへのアクセスは Observable 連鎖で追跡される。
    @ObservationIgnored private let dropboxStore: DropboxPhotoStore
    @ObservationIgnored private let localStore: LocalPhotoStore
    /// 非 nil の場合、Dropbox はこのパス集合のものだけを対象にする（場所アルバム等のフィルタ用）。
    /// ローカル側は注入された `localStore`（必要なら localIdentifiers で絞り込み済み）に従う。
    @ObservationIgnored private let cloudPathFilter: Set<String>?

    /// 表示用の確定済み配列（描画パスは O(1) でこれを読むだけ）。
    /// merge + sort はメインアクタ外（Task.detached）で行い、完成品をここへ代入する。
    public private(set) var items: [MergedPhotoItem] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    public init(
        dropboxStore: DropboxPhotoStore,
        localStore: LocalPhotoStore? = nil,
        cloudPathFilter: Set<String>? = nil
    ) {
        self.dropboxStore = dropboxStore
        self.localStore = localStore ?? LocalPhotoStore()
        self.cloudPathFilter = cloudPathFilter
        observeStores()
    }

    // MARK: - Off-main merge/sort

    /// `localStore.items` / `dropboxStore.items` の変化を Observation で監視し、
    /// 変化のたびに再構築をスケジュールする。onChange は一度きりなので毎回再登録する。
    private func observeStores() {
        withObservationTracking {
            _ = localStore.items
            _ = dropboxStore.items
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStores()      // re-arm
                self.rebuildItems()
            }
        }
    }

    /// 両ストアの配列をスナップショットし、メインアクタ外で filter + map + sort して
    /// 完成した配列をメインで代入する（68k 件規模のソートで描画を固めないため）。
    func rebuildItems() {
        let localSnapshot = localStore.items                  // [LocalPhotoItem]（Sendable）
        let cloudSnapshot = dropboxStore.items                // [DropboxFileItem]（Sendable）
        let filter = cloudPathFilter
        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let local = localSnapshot.map(MergedPhotoItem.local)
            let cloud = MergedPhotoStore.filteredCloudItems(cloudSnapshot, filter: filter)
                .map(MergedPhotoItem.cloud)
            // グリッドは下が新しい（昇順＋ defaultScrollAnchor(.bottom)）。
            let merged = (local + cloud).sortedByCaptureDateAscending()
            if Task.isCancelled { return }
            await self?.setItems(merged)
        }
    }

    private func setItems(_ newItems: [MergedPhotoItem]) {
        items = newItems
    }
}

// MARK: - PhotoStore conformance

extension MergedPhotoStore: PhotoStore {
    public typealias Item = MergedPhotoItem

    public var state: PhotoLoadState {
        Self.resolveState(
            localState: localStore.state,
            hasLocalAssets: !localStore.assets.isEmpty,
            hasDropbox: !dropboxStore.items.isEmpty,
            dropboxBusy: dropboxBusy
        )
    }

    /// Dropbox がまだ取得中か（ロード中 or 初回同期/差分取得中）。
    /// T2: ローカルが空でも Dropbox 取得完了前に "No photos" を出さないために使う。
    private var dropboxBusy: Bool {
        if case .loading = dropboxStore.loadStatus { return true }
        switch dropboxStore.syncState {
        case .initialSync, .fetchingDelta: return true
        default: return false
        }
    }

    // MARK: - Pure helpers (テスト対象)

    /// Dropbox アイテムをパスフィルタで絞り込む。フィルタが nil なら全件。
    nonisolated static func filteredCloudItems(
        _ items: [DropboxFileItem], filter: Set<String>?
    ) -> [DropboxFileItem] {
        guard let filter else { return items }
        return items.filter { filter.contains($0.path) }
    }

    /// 統合状態を解決する。ローカル権限が無い（needsSetup/failed）場合は全体をブロックし、
    /// いずれかにアイテムがあれば loaded、無ければローカルの読み込み状況に従う。
    nonisolated static func resolveState(
        localState: PhotoLoadState, hasLocalAssets: Bool, hasDropbox: Bool,
        dropboxBusy: Bool = false
    ) -> PhotoLoadState {
        switch localState {
        case .needsSetup, .failed:
            return localState
        default:
            break
        }
        if hasLocalAssets || hasDropbox { return .loaded }
        switch localState {
        case .idle:    return .idle
        case .loading: return .loading
        // T2: ローカルが空でも Dropbox 取得中なら empty にせず loading を維持する。
        default:       return dropboxBusy ? .loading : .empty
        }
    }

    public func start() async {
        // ローカル写真の権限要求・アセット読み込み。
        await localStore.start()
        // Dropbox キャッシュから即時ロード（SyncEngine は HomeView が管理するため起動しない）。
        await dropboxStore.loadItems()
        // 読み込み直後に一度ビルド（Observation が取りこぼしても確実に反映）。
        rebuildItems()
    }

    public func retry() async {
        // ローカル権限拒否時に設定アプリへ誘導する。
        await localStore.retry()
    }

    public func thumbnail(for item: MergedPhotoItem) async -> UIImage? {
        switch item {
        case .local(let local): return await localStore.thumbnail(for: local)
        case .cloud(let cloud): return await dropboxStore.thumbnail(for: cloud)
        }
    }

    public func thumbnail(for item: MergedPhotoItem, targetSize: CGSize) async -> UIImage? {
        switch item {
        case .local(let local): return await localStore.thumbnail(for: local, targetSize: targetSize)
        // Dropbox のサムネイルは API 側で固定サイズ（w128h128）のため targetSize は使わない（設計通り）。
        case .cloud(let cloud): return await dropboxStore.thumbnail(for: cloud)
        }
    }

    public func fullImage(for item: MergedPhotoItem) async -> UIImage? {
        switch item {
        case .local(let local): return await localStore.fullImage(for: local)
        case .cloud(let cloud): return await dropboxStore.fullImage(for: cloud)
        }
    }

    public func location(for item: MergedPhotoItem) async -> CLLocationCoordinate2D? {
        switch item {
        case .local(let local): return await localStore.location(for: local)
        case .cloud(let cloud): return await dropboxStore.location(for: cloud)
        }
    }

    public func metadata(for item: MergedPhotoItem) async -> PhotoExifInfo? {
        switch item {
        case .local(let local): return await localStore.metadata(for: local)
        case .cloud(let cloud): return await dropboxStore.metadata(for: cloud)
        }
    }
}
#endif
