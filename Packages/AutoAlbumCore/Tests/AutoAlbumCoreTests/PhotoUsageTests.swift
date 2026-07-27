import Foundation
import Testing
@testable import AutoAlbumCore

/// 利用カウンタ（閲覧/再生/共有）の台帳と refKey 正規化。
@Suite("PhotoUsage (view/play/share counters)", .serialized)
struct PhotoUsageTests {

    @Test("increment はレコードを作成し種別ごとに加算する")
    func incrementCreatesAndCounts() async {
        let store = UsageStore(isStoredInMemoryOnly: true)
        await store.increment(.view, refKey: "L-a")
        await store.increment(.view, refKey: "L-a")
        await store.increment(.share, refKey: "L-a")
        await store.increment(.play, refKey: "L-b")
        let counts = await store.counts(forRefKeys: ["L-a", "L-b", "L-none"])
        #expect(counts["L-a"] == PhotoUsageCounts(viewCount: 2, playCount: 0, shareCount: 1))
        #expect(counts["L-b"] == PhotoUsageCounts(viewCount: 0, playCount: 1, shareCount: 0))
        #expect(counts["L-none"] == nil)   // 記録なしは含めない
    }

    @Test("canonicalRefKey: refKey はそのまま・パスは C-・それ以外は L-")
    func canonicalRefKey() {
        #expect(AutoAlbumEngine.canonicalRefKey(for: "L-abc") == "L-abc")
        #expect(AutoAlbumEngine.canonicalRefKey(for: "C-/photos/x.jpg") == "C-/photos/x.jpg")
        #expect(AutoAlbumEngine.canonicalRefKey(for: "/photos/x.jpg") == "C-/photos/x.jpg")
        #expect(AutoAlbumEngine.canonicalRefKey(for: "ABCD-1234/L0/001") == "L-ABCD-1234/L0/001")
    }
}
