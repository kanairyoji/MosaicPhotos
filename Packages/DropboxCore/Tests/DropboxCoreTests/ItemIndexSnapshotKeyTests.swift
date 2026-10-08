import Foundation
import Testing
@testable import DropboxCore

/// **控えを使ってよいかの鍵の約束**（ADR-258・材料の約束＝ADR-251 の形）。
///
/// ⚠️⚠️ ここが本丸。鍵は両側から壊れる:
/// - **鈍すぎる**と、中身が変わったのに古い控えを使う（写真が消えているのに一覧に出る）。
/// - **鋭すぎる**と、鍵が毎回変わって控えが**一度も当たらない**＝直したつもりで 9 秒を払い続ける。
///   ADR-250 でまさにこれを踏んだ（`itemsRevision` は撮影日の問い合わせでも進むので、
///   流用したゲートが実機で 1 回も効かなかった）。だから**両方向を縛る**。
@Suite("軽い表の控えの鍵")
struct ItemIndexSnapshotKeyTests {

    private func item(_ path: String, hash: String = "h1",
                      date: Date? = nil) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent,
                        contentHash: hash, captureDate: date)
    }

    private func seeded() async -> DropboxCacheStore {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acc1",
                               added: [item("/a.jpg"), item("/b.jpg")],
                               removed: [], newCursor: "c1")
        return cache
    }

    /// ⚠️ **これが無いと「直した」が嘘になる**。差分の無いポーリングでも `applyDelta` は
    /// カーソルを書くので、カーソルを鍵にすると毎回変わって控えが当たらない。
    @Test("変化の無いポーリングでは鍵が動かない（控えが当たり続ける）")
    func keyIsStableAcrossNoChangePolls() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        // 差分なし＝追加も削除もない applyDelta（カーソルだけ進む）。
        for cursor in ["c2", "c3", "c4"] {
            await cache.applyDelta(accountId: "acc1", added: [], removed: [], newCursor: cursor)
        }
        #expect(await cache.snapshotKeyForTesting() == before, """
                変化が無いのに鍵が動いた＝控えが一度も当たらない（9 秒を毎起動払い続ける）。
                """)
    }

    @Test("写真が増えたら鍵が変わる")
    func keyChangesWhenPhotosAreAdded() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        await cache.applyDelta(accountId: "acc1", added: [item("/c.jpg")],
                               removed: [], newCursor: "c2")
        #expect(await cache.snapshotKeyForTesting() != before,
                "増えたのに古い控えを使う（新しい写真が解析候補に出ない）")
    }

    @Test("写真が消えたら鍵が変わる")
    func keyChangesWhenPhotosAreRemoved() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        await cache.applyDelta(accountId: "acc1", added: [], removed: ["/a.jpg"],
                               newCursor: "c2")
        #expect(await cache.snapshotKeyForTesting() != before,
                "消えたのに古い控えを使う（開けない写真が一覧に残る＝diagnostics-82 の形）")
    }

    /// ⚠️ 撮影日は控えに**載っている**値なので、変われば鍵も変わらなければならない。
    @Test("撮影日を訊いたら鍵が変わる")
    func keyChangesAfterACaptureDateProbe() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        let changed = await cache.recordCaptureDateProbe(
            path: "/a.jpg", captureDate: Date(timeIntervalSince1970: 1_500_000_000),
            latitude: nil, longitude: nil)
        #expect(changed, "前提: 記録できていない（以降の assert が空振りする）")
        #expect(await cache.snapshotKeyForTesting() != before,
                "撮影日が変わったのに古い控えを使う（並び順と顔の時期グループが狂う）")
    }

    /// ⚠️ 「訊いたが EXIF が無かった」も鍵を変える——`exifProbedAt` が立つので
    /// 控えの `probed` が変わる（これを見落とすと、訊き終わった写真を永久に訊き直す）。
    @Test("撮影日が「無かった」ときも鍵が変わる")
    func keyChangesWhenTheProbeFoundNothing() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        _ = await cache.recordCaptureDateProbe(path: "/a.jpg", captureDate: nil,
                                               latitude: nil, longitude: nil)
        #expect(await cache.snapshotKeyForTesting() != before,
                "「無かった」の記録が鍵に出ていない")
    }

    /// ⚠️ 件数では捕まえられない唯一の変化（同じパスのまま中身が差し替わる）。
    /// Dropbox 上で写真を編集・上書きするとこうなる。hash は控えに載っている。
    @Test("中身が差し替わったら鍵が変わる（件数は同じ）")
    func keyChangesWhenContentIsReplaced() async {
        let cache = await seeded()
        let before = await cache.snapshotKeyForTesting()
        await cache.applyDelta(accountId: "acc1",
                               added: [item("/a.jpg", hash: "h2-replaced")],
                               removed: [], newCursor: "c2")
        #expect(await cache.snapshotKeyForTesting() != before, """
                パスも件数も同じまま hash だけ変わった場合に鍵が動かない
                ——古い hash で解析を公開し続ける（受け手と突き合わない）。
                """)
    }

    /// ⚠️ インメモリの店は控えを**書かない**。控えは `Caches` の 1 つの固定ファイルで、
    /// 小さな fixture どうしでは鍵がたまたま一致する（2 行・2 件・0 回）ので、
    /// 並行するテストが互いの控えを読み込み得る。
    @Test("インメモリの店は控えを書かない（テストどうしが干渉しない）")
    func ephemeralStoresDoNotTouchTheSnapshot() async {
        let cache = await seeded()
        await cache.removeIndexSnapshotForTesting()
        _ = await cache.cachedPhotoRefs()       // 表を作らせる
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxKit/item-index.bin")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "インメモリの店が控えを書いた（他のテストの表を壊し得る）")
    }
}
