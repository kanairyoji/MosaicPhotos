#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// クラウド写真の**撮影日時の穴埋め**（ADR-201）。
///
/// ⚠️ 前提（一次情報で確認）: Dropbox は `list_folder` / `list_folder/continue` /
/// `get_thumbnail_batch` で **`media_info` を返さない**（2019-12-02 以降）。したがって一覧から
/// 得られる日付は `client_modified`＝**アップロード時刻**で、撮影日時ではない。
/// 撮影日時の唯一の出典は `files/get_metadata` を 1 枚ずつ叩くこと（数秒/枚）。
///
/// その前提から、守らなければならない性質が 3 つある。
///   1. 訊いた結果を記録する（**無かったことも**）——でないと 6.8 万枚ぶん毎回往復する
///   2. 訊いて得た撮影日時を、後続の同期（一覧の日付＝アップロード時刻）が**上書きしない**
///   3. 中身が差し替わったら訊き直す
@Suite("撮影日時の穴埋め（ADR-201）")
struct CaptureDateProbeTests {

    private let uploadedAt = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11
    private let shotAt = Date(timeIntervalSince1970: 1_400_000_000)       // 2014-05

    private func store(with item: DropboxFileItem) async -> DropboxCacheStore {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "acc1", added: [item], removed: [], newCursor: "c1")
        return store
    }

    private func item(hash: String = "h1") -> DropboxFileItem {
        DropboxFileItem(path: "/a.jpg", name: "a.jpg", contentHash: hash, captureDate: uploadedAt)
    }

    @Test("まだ訊いていない写真が対象に挙がる")
    func unprobedItemsAreListed() async {
        let store = await store(with: item())
        #expect(await store.pathsNeedingCaptureDateProbe(limit: 10) == ["/a.jpg"])
        #expect(await store.captureDateProbePendingCount() == 1)
    }

    @Test("訊いて得た撮影日時が記録され、対象から外れる")
    func probeRecordsTheCaptureDate() async {
        let store = await store(with: item())

        let changed = await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: shotAt,
                                                         latitude: nil, longitude: nil)

        #expect(changed, "表示の値が変わったのに変化なしと報告している")
        #expect(await store.cachedItems(accountId: "acc1").first?.captureDate == shotAt)
        #expect(await store.pathsNeedingCaptureDateProbe(limit: 10).isEmpty, "同じ写真をまた訊く")
    }

    /// ⚠️ **無かったことも記録する**（CLAUDE.md 性能原則 3・無いものを繰り返し探さない）。
    /// EXIF の無い写真は何度訊いても無いので、記録しないと毎回 1 往復ぶん無駄になる。
    @Test("EXIF が無い写真も「訊いた」と記録され、二度目は訊かない")
    func negativeResultIsRemembered() async {
        let store = await store(with: item())

        let changed = await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: nil,
                                                         latitude: nil, longitude: nil)

        #expect(!changed, "何も変わっていないのに一覧の作り直しを要求している")
        #expect(await store.cachedItems(accountId: "acc1").first?.captureDate == uploadedAt,
                "取れなかったのに既存の日付を消した")
        #expect(await store.pathsNeedingCaptureDateProbe(limit: 10).isEmpty,
                "無いと分かっている写真を毎回訊き直す（6.8 万枚ぶんの往復になる）")
    }

    /// ⚠️ **本命の回帰**: 同期が回るたびに一覧の日付（アップロード時刻）で上書きされると、
    /// 直したはずの並びが元へ戻り、しかも毎回全行がダーティになる（ディスク書き込みの山）。
    @Test("後続の同期は、訊いて得た撮影日時を上書きしない")
    func laterSyncDoesNotOverwriteTheProbedDate() async {
        let store = await store(with: item())
        await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: shotAt,
                                           latitude: nil, longitude: nil)
        let revision = await store.currentItemsRevision()

        // 同じ写真が一覧に再び現れる（中身は同じ＝contentHash も同じ）。
        await store.applyDelta(accountId: "acc1", added: [item()], removed: [], newCursor: "c2")

        #expect(await store.cachedItems(accountId: "acc1").first?.captureDate == shotAt,
                "アップロード時刻で上書きされた（並びが元に戻る）")
        #expect(await store.currentItemsRevision() == revision,
                "中身が同じなのに行を書き直している（毎回の同期でディスクを叩く）")
    }

    /// 中身が差し替わったら、撮影日時も訊き直す（無効化経路・性能原則 3 の但し書き）。
    @Test("中身が変わったら、もう一度訊く")
    func changedContentIsProbedAgain() async {
        let store = await store(with: item(hash: "h1"))
        await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: shotAt,
                                           latitude: nil, longitude: nil)
        #expect(await store.pathsNeedingCaptureDateProbe(limit: 10).isEmpty)

        await store.applyDelta(accountId: "acc1", added: [item(hash: "h2")], removed: [],
                               newCursor: "c2")

        #expect(await store.pathsNeedingCaptureDateProbe(limit: 10) == ["/a.jpg"],
                "差し替わった写真の撮影日時を訊き直していない")
    }
}
#endif
