#if canImport(UIKit)
import AVFoundation
import CoreLocation
import DropboxCore
import MosaicSupport
import Observation
import PhotoSourceKit
import UIKit

/// 「クラウド」画面のストア：写真と動画を撮影日時の順に並べる（ADR-282）。
///
/// ⚠️ `DropboxPhotoStore.items` を写真と動画の一覧に変えなかったのは、`items` を読む側
/// （解析候補・場所・共有アルバム・顔の計測）がどれも写真を前提にしているから。
/// 動画を見せる画面だけがこのストアを通す。取得・状態・同期はすべて `photos` に任せる。
@MainActor
@Observable
public final class DropboxMediaStore: PhotoStore {
    public typealias Item = DropboxFileItem

    @ObservationIgnored public let photos: DropboxPhotoStore
    /// 写真と動画を撮影日時の昇順に並べたもの（並べ替えはメインの外）。
    public private(set) var items: [DropboxFileItem] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var generation = GenerationGuard()
    @ObservationIgnored private var isObserving = false

    public init(photos: DropboxPhotoStore) {
        self.photos = photos
        // 監視は `start()` で張る（SwiftUI の再評価で生まれる使い捨てのインスタンスを動かさない
        // ＝`MergedPhotoStore` と同じ作法）。
    }

    public var state: PhotoLoadState { photos.state }
    public var includesVideos: Bool { true }

    public func start() async {
        if !isObserving {
            isObserving = true
            observe()
        }
        rebuild()
        await photos.start()
    }

    public func retry() async { await photos.retry() }

    private func observe() {
        withObservationTracking {
            _ = photos.items
            _ = photos.videoItems
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let photoItems = photos.items
        let videoItems = photos.videoItems
        // 動画が無ければ並べ直さない（写真の一覧は既に撮影日時の順＝コピーもしない）。
        guard !videoItems.isEmpty else {
            rebuildTask?.cancel()
            _ = generation.next()
            if items != photoItems { items = photoItems }
            return
        }
        let token = generation.next()
        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let merged = Self.merged(photos: photoItems, videos: videoItems)
            await MainActor.run { [weak self] in
                guard let self, self.generation.isCurrent(token), !Task.isCancelled else { return }
                if self.items != merged { self.items = merged }
            }
        }
    }

    /// 写真と動画を撮影日時の昇順に並べる（純ロジック・テスト対象）。
    nonisolated static func merged(photos: [DropboxFileItem],
                                   videos: [DropboxFileItem]) -> [DropboxFileItem] {
        var all = photos
        all.append(contentsOf: videos)
        all.sortByCaptureDateAscending()
        return all
    }

    // MARK: - 取得は `photos` に任せる

    public func thumbnail(for item: DropboxFileItem) async -> UIImage? {
        await photos.thumbnail(for: item)
    }
    public func prefetch(_ items: [DropboxFileItem], targetSize: CGSize) {
        photos.prefetch(items, targetSize: targetSize)
    }
    public func cancelPrefetch(_ items: [DropboxFileItem]) { photos.cancelPrefetch(items) }
    public func fullImage(for item: DropboxFileItem) async -> UIImage? {
        await photos.fullImage(for: item)
    }
    public func prefetchFullImage(for item: DropboxFileItem) { photos.prefetchFullImage(for: item) }
    public func location(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        await photos.location(for: item)
    }
    public func cachedLocation(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        await photos.cachedLocation(for: item)
    }
    public func metadata(for item: DropboxFileItem) async -> PhotoExifInfo? {
        await photos.metadata(for: item)
    }
    public func originalForSharing(_ item: DropboxFileItem) async -> SharedOriginal? {
        await photos.originalForSharing(item)
    }
    public func setFavorite(_ item: DropboxFileItem, _ isFavorite: Bool) async -> Bool {
        await photos.setFavorite(item, isFavorite)
    }
    public func playerItem(for item: DropboxFileItem) async -> AVPlayerItem? {
        await photos.playerItem(for: item)
    }
    public func streamingInfo(for item: DropboxFileItem) -> VideoStreamingInfo? {
        photos.streamingInfo(for: item)
    }
    public func externalViewer(for item: DropboxFileItem) -> ExternalVideoViewer? {
        photos.externalViewer(for: item)
    }
}
#endif
