#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// `DropboxCacheStore`（actor）の SwiftData メタデータ（ファイル一覧・同期カーソル）を検証する。
@Suite("DropboxCacheStore metadata")
struct DropboxCacheStoreMetadataTests {

    @Test("新規ストアの cachedItems は空")
    func cachedItemsEmptyInitially() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        #expect(await store.cachedItems(accountId: "acc1").isEmpty)
    }

    @Test("applyDelta は新規アイテムを挿入する")
    func applyDeltaInserts() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let item = DropboxFileItem(path: "/a.jpg", name: "a.jpg", contentHash: "hash1")
        await store.applyDelta(accountId: "acc1", added: [item], removed: [], newCursor: "c1")
        let cached = await store.cachedItems(accountId: "acc1")
        #expect(cached.count == 1)
        #expect(cached[0].path == "/a.jpg")
    }

    @Test("applyDelta は削除指定アイテムをメタデータから消す")
    func applyDeltaRemoves() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let item = DropboxFileItem(path: "/a.jpg", name: "a.jpg", contentHash: "hash1")
        await store.applyDelta(accountId: "acc1", added: [item], removed: [], newCursor: "c1")
        await store.applyDelta(accountId: "acc1", added: [], removed: ["/a.jpg"], newCursor: "c2")
        #expect(await store.cachedItems(accountId: "acc1").isEmpty)
    }

    @Test("contentHash 不変時は name を更新する")
    func applyDeltaUpdatesNameWithoutHashChange() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let item1 = DropboxFileItem(path: "/a.jpg", name: "a.jpg", contentHash: "same")
        let item2 = DropboxFileItem(path: "/a.jpg", name: "a-renamed.jpg", contentHash: "same")
        await store.applyDelta(accountId: "acc1", added: [item1], removed: [], newCursor: "c1")
        await store.applyDelta(accountId: "acc1", added: [item2], removed: [], newCursor: "c2")
        let cached = await store.cachedItems(accountId: "acc1")
        #expect(cached.count == 1)
        #expect(cached[0].name == "a-renamed.jpg")
    }

    @Test("新規ストアの syncStateInfo は nil")
    func syncStateNilInitially() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        #expect(await store.syncStateInfo(accountId: "acc1") == nil)
    }

    @Test("applyDelta は syncState にカーソルを保存する")
    func applyDeltaSavesCursor() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "acc1", added: [], removed: [], newCursor: "cursor-xyz")
        let state = await store.syncStateInfo(accountId: "acc1")
        #expect(state?.cursor == "cursor-xyz")
        #expect(state?.lastSyncedAt != nil)
    }

    @Test("clearAll はアカウントのメタデータとカーソルを全消去する")
    func clearAllRemovesMetadata() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let items = [
            DropboxFileItem(path: "/a.jpg", name: "a.jpg"),
            DropboxFileItem(path: "/b.jpg", name: "b.jpg"),
        ]
        await store.applyDelta(accountId: "acc1", added: items, removed: [], newCursor: "c1")
        await store.clearAll(accountId: "acc1")
        #expect(await store.cachedItems(accountId: "acc1").isEmpty)
        #expect(await store.syncStateInfo(accountId: "acc1") == nil)
    }
}
#endif
