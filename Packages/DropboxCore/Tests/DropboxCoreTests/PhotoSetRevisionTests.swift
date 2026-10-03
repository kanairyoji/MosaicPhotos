#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// **「写真が増減したか」の札は、それ以外では動かない**（ADR-250・実機ログ diagnostics-104）。
///
/// ⚠️⚠️ **なぜ必要になったか**: 解析候補の列挙（8.6 万件・約 11 秒）を飛ばすゲートに
/// `itemsRevision` を使ったら、**1 回も効かなかった**——実機で `候補の列挙を見送る` が 0 件、
/// 11 回とも列挙していた。あの札は「一覧を作り直す必要があるか」用で、
/// **撮影日の問い合わせ**（1 セッション 789 回）や**撮影地の解決**でも進む。
/// つまりほぼ常に動いているので、「候補が変わったか」を訊くと**いつも『変わった』**と答える。
///
/// ⚠️ これは ADR-240 と**同じ過ち**（1 つの版に 2 つ目の意味を兼ねさせた）。
/// 対策も同じ: **新しい問いには新しい札を立てる。**
@Suite("写真の集合の版（ADR-250）")
struct PhotoSetRevisionTests {

    private func item(_ path: String, hash: String = "h", date: Date? = nil) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent,
                        contentHash: hash, captureDate: date)
    }

    @Test("写真が増えたら進む")
    func advancesWhenPhotosAreAdded() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        let before = await store.currentPhotoSetRevision()

        await store.applyDelta(accountId: "a", added: [item("/a.jpg")], removed: [], newCursor: "c1")

        #expect(await store.currentPhotoSetRevision() > before, "増えたのに進んでいない")
    }

    @Test("写真が減ったら進む")
    func advancesWhenPhotosAreRemoved() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "a", added: [item("/a.jpg")], removed: [], newCursor: "c1")
        let before = await store.currentPhotoSetRevision()

        await store.applyDelta(accountId: "a", added: [], removed: ["/a.jpg"], newCursor: "c2")

        #expect(await store.currentPhotoSetRevision() > before, "減ったのに進んでいない")
    }

    /// ⚠️⚠️ **ここが本丸**。撮影日を訊いても、撮影地を解決しても、集合は変わっていない。
    /// ここが進むと、候補のゲートが永久に効かなくなる（実機で実際にそうなった）。
    @Test("撮影日を訊いても、撮影地を解決しても進まない")
    func doesNotAdvanceForProbesOrLocation() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "a", added: [item("/a.jpg")], removed: [], newCursor: "c1")
        let before = await store.currentPhotoSetRevision()
        let itemsBefore = await store.currentItemsRevision()

        _ = await store.recordCaptureDateProbe(path: "/a.jpg",
                                               captureDate: Date(timeIntervalSince1970: 1_400_000_000),
                                               latitude: nil, longitude: nil)
        await store.updateLocation(path: "/a.jpg", latitude: 35.0, longitude: 139.0)

        #expect(await store.currentPhotoSetRevision() == before, """
            撮影日・撮影地で集合の版が進んだ。これが起きると候補の列挙を飛ばせなくなる
            （実機では 8.6 万件の列挙を 11 回とも払っていた）。
            """)
        // fixture の前提: 一覧側の版は**進んでいる**こと（進まないならこのテストは何も見ていない）。
        #expect(await store.currentItemsRevision() > itemsBefore,
                "fixture: 一覧の版すら進んでいない（2 つの札を区別できていない）")
    }

    /// ⚠️ 中身の差し替え（同じパスの更新）でも進めない——同じ写真のままなので候補は変わらない。
    @Test("同じパスの中身が変わっただけでは進まない")
    func doesNotAdvanceOnContentUpdate() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "a", added: [item("/a.jpg", hash: "h1")],
                               removed: [], newCursor: "c1")
        let before = await store.currentPhotoSetRevision()

        await store.applyDelta(accountId: "a", added: [item("/a.jpg", hash: "h2")],
                               removed: [], newCursor: "c2")

        #expect(await store.currentPhotoSetRevision() == before, "中身の差し替えで集合の版が進んだ")
    }

    @Test("変化の無いポーリングでは進まない")
    func doesNotAdvanceOnEmptyDelta() async {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "a", added: [item("/a.jpg")], removed: [], newCursor: "c1")
        let before = await store.currentPhotoSetRevision()

        await store.applyDelta(accountId: "a", added: [], removed: [], newCursor: "c2")

        #expect(await store.currentPhotoSetRevision() == before, "空の delta で進んだ")
    }
}
#endif
