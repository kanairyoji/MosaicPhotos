#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import DropboxCore

/// `DropboxCacheStore` のバイナリ無効化と LRU 破棄（`CacheUsageEntry` ベース）を検証する。
/// SwiftData はインメモリ、バイナリは実ディスク（テスト後にクリア）。
@Suite("DropboxCacheStore cache")
@MainActor
struct DropboxCacheStoreCacheTests {

    private func makeImage(side: Int = 8) -> UIImage {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Invalidation

    @Test("invalidate でサムネイルがメモリ・ディスクから消える")
    func invalidateRemovesThumbnail() async throws {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let path = "/inv-\(UUID().uuidString).jpg"
        await store.storeThumbnail(makeImage(), for: path)
        // ⚠️ storeThumbnail のディスク書込みは detached。先に書込み完了を待たないと、
        // invalidate の後で遅延書込みが着地してファイルが復活する（テストの競合）。
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await store.thumbnail(for: path) != nil)

        await store.invalidate(path: path)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await store.thumbnail(for: path) == nil)
    }

    @Test("contentHash 変化時の applyDelta はキャッシュ済みバイナリを無効化する")
    func contentHashChangeInvalidatesBinary() async throws {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let path = "/hashchg-\(UUID().uuidString).jpg"
        await store.applyDelta(accountId: "acc", added: [DropboxFileItem(path: path, name: "a.jpg", contentHash: "h1")], removed: [], newCursor: "c1")
        await store.storeThumbnail(makeImage(), for: path)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await store.thumbnail(for: path) != nil)

        // 同じパスで contentHash を変える → invalidate が走りバイナリが消える。
        await store.applyDelta(accountId: "acc", added: [DropboxFileItem(path: path, name: "a.jpg", contentHash: "h2")], removed: [], newCursor: "c2")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await store.thumbnail(for: path) == nil)
    }

    @Test("contentHash 不変の applyDelta はバイナリを保持する")
    func sameHashKeepsBinary() async throws {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let path = "/samehash-\(UUID().uuidString).jpg"
        await store.applyDelta(accountId: "acc", added: [DropboxFileItem(path: path, name: "a.jpg", contentHash: "h1")], removed: [], newCursor: "c1")
        await store.storeThumbnail(makeImage(), for: path)
        try await Task.sleep(nanoseconds: 200_000_000)
        // 名前だけ変えて同じ hash で再 applyDelta → バイナリは保持される。
        await store.applyDelta(accountId: "acc", added: [DropboxFileItem(path: path, name: "renamed.jpg", contentHash: "h1")], removed: [], newCursor: "c2")
        #expect(await store.thumbnail(for: path) != nil)
        await store.invalidate(path: path)  // cleanup
    }

    // MARK: - LRU eviction

    @Test("バイト上限を超えると LRU 破棄で件数が減る（メモリ・ディスク両方）")
    func enforceCapacityEvicts() async throws {
        // 上限を小さくして、10件保存で必ず破棄が走るようにする。
        let store = DropboxCacheStore(thumbnailByteLimit: 1_500, isStoredInMemoryOnly: true)
        let prefix = "/lru-\(UUID().uuidString)-"
        let paths = (0..<10).map { "\(prefix)\($0).jpg" }
        for p in paths {
            await store.storeThumbnail(makeImage(side: 16), for: p)
        }
        // 全 detached 書込み + recordUsage + enforceCapacity の収束を待つ。
        try await Task.sleep(nanoseconds: 1_000_000_000)

        var surviving = 0
        for p in paths where await store.thumbnail(for: p) != nil { surviving += 1 }
        #expect(surviving < 10)   // 破棄が起きた
        #expect(surviving >= 1)   // 全消しではない

        for p in paths { await store.invalidate(path: p) }  // cleanup
    }
}
#endif
