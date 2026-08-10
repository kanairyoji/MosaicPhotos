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

    // MARK: - 変更リビジョン（ADR-95）

    /// 実機 diagnostics-38 の回帰: 変化のない同期ポーリングでも毎回 68,200 行を fetch し、
    /// 値型 68,200 個を作って署名を比べ、大半を捨てていた（`cache.fetchItems` 993ms / 1165ms →
    /// 直後にメインが 2.8s / 3.5s ブロック）。変わっていないものを取り直さないための札。
    @Test("itemsRevision: 実際に変わったときだけ進む")
    func revisionAdvancesOnlyOnRealChange() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let start = await store.currentItemsRevision()

        // 空デルタ（＝変更なしのポーリング）ではカーソルだけ進み、札は据え置き。
        await store.applyDelta(accountId: "acc1", added: [], removed: [], newCursor: "c1")
        #expect(await store.currentItemsRevision() == start, "変化なしのポーリングで札が進んでいる")

        let item = DropboxFileItem(path: "/a.jpg", name: "a.jpg", contentHash: "hash1")
        await store.applyDelta(accountId: "acc1", added: [item], removed: [], newCursor: "c2")
        let afterInsert = await store.currentItemsRevision()
        #expect(afterInsert != start, "挿入で札が進んでいない")

        await store.applyDelta(accountId: "acc1", added: [], removed: [], newCursor: "c3")
        #expect(await store.currentItemsRevision() == afterInsert, "空デルタで札が進んでいる")

        await store.applyDelta(accountId: "acc1", added: [], removed: ["/a.jpg"], newCursor: "c4")
        #expect(await store.currentItemsRevision() != afterInsert, "削除で札が進んでいない")
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
