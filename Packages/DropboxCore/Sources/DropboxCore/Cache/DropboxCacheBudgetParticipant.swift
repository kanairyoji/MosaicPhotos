#if canImport(UIKit)
import Foundation
import ImageCacheKit

/// `DropboxCacheStore` の種別（サムネ／本体画像）を、アプリ全体のキャッシュ予算（ADR-185）に参加させる。
/// 追い出しの実体は store が持つ（LRU・先読み優先）。ここは協調役との窓口だけ。
final class DropboxCacheBudgetParticipant: BudgetedCache, @unchecked Sendable {
    let budgetID: String
    let budgetTier: CacheBudgetTier
    private let kind: CacheUsageEntry.CacheKind
    private weak var store: DropboxCacheStore?

    init(kind: CacheUsageEntry.CacheKind, store: DropboxCacheStore) {
        self.kind = kind
        self.store = store
        switch kind {
        case .thumbnail: budgetID = "dropbox.thumbnails"; budgetTier = .thumbnails
        case .fullImage: budgetID = "dropbox.fullImages"; budgetTier = .fullImages
        }
    }

    func budgetUsage() async -> Int { await store?.usageTotal(kind) ?? 0 }
    func budgetOldestAccess() async -> Date? { await store?.oldestAccess(kind: kind) }
    func budgetEvict(bytes: Int) async -> Int { await store?.evict(kind: kind, bytes: bytes) ?? 0 }
}

extension DropboxCacheStore {
    /// 予算へ参加する（`DropboxPhotoStore` が生成後に 1 回呼ぶ。テスト用のインメモリ store は呼ばない）。
    func joinCacheBudget() async {
        guard budgetParticipants.isEmpty else { return }
        let thumbs = DropboxCacheBudgetParticipant(kind: .thumbnail, store: self)
        let full = DropboxCacheBudgetParticipant(kind: .fullImage, store: self)
        budgetParticipants = [thumbs, full]
        await CacheBudgetCoordinator.shared.register(thumbs)
        await CacheBudgetCoordinator.shared.register(full)
    }
}
#endif
