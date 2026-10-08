import Foundation
import SwiftData
import Testing
@testable import DropboxCore

/// **起動を跨いで表を作り直さないこと**（ADR-258/259・実機ログ diagnostics-105）。
///
/// ⚠️⚠️ **これが抜けていた理由がそのまま教訓**。
/// 既存のテスト（`CloudContentHashProjectionTests`）は 6 か所で
/// `itemIndexBuildsForTesting == 1` を確かめていた——「変化が無いのに引き直していない」。
/// 正しい assert だが、**店 1 つ＝1 回の起動**なので、
/// 「毎起動 1 回作り直す」は**望ましい性質として固定されていた**。
/// それが実機の `cache.buildItemIndex` 9.0 秒 × 毎起動そのものだった。
///
/// ⚠️ 1 回の起動の中だけを見るテストは、**起動ごとに繰り返す費用を原理的に見つけられない**。
/// だから容器を共有した 2 つ目の店（＝次の起動）で確かめる。
@Suite("軽い表（起動を跨ぐ）")
struct ItemIndexAcrossLaunchesTests {

    /// 1 つの一時ディレクトリに、ディスクの容器と控えの置き場を用意する。
    /// ⚠️ テストごとに別の場所（並行実行で互いの控えを上書きしないように）。
    private final class Fixture {
        let dir: URL
        let container: ModelContainer
        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("itemindex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let schema = Schema([CachedDropboxItem.self, DropboxSyncState.self,
                                 CacheUsageEntry.self])
            let config = ModelConfiguration(schema: schema,
                                            url: dir.appendingPathComponent("DropboxCache.store"))
            container = try ModelContainer(for: schema, configurations: [config])
        }
        /// 同じ容器・同じ控えを見る新しい店＝**次の起動**。
        func relaunch() -> DropboxCacheStore {
            DropboxCacheStore(testContainer: container, snapshotDirectory: dir)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    private func item(_ path: String, hash: String = "h1",
                      date: Date? = nil) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent,
                        contentHash: hash, captureDate: date)
    }

    /// ⚠️ **本丸**。2 回目の起動で表を作り直したら、実機の 9 秒が毎起動戻る。
    @Test("2 回目の起動では表を作り直さない（控えから復元する）")
    func secondLaunchRestoresFromTheSnapshot() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1",
                               added: (0..<50).map { item("/p/\($0).jpg") },
                               removed: [], newCursor: "c1")
        let built = await first.cachedPhotoRefs()
        #expect(built.count == 50, "前提: 表が作れていない（以降の assert が空振りする）")
        #expect(await first.itemIndexBuildsForTesting == 1, "前提: 1 回目は作る")

        let second = fx.relaunch()
        let restored = await second.cachedPhotoRefs()
        #expect(await second.itemIndexBuildsForTesting == 0, """
                2 回目の起動で 10.8 万行を歩き直している
                ——実機ではこれが `cache.buildItemIndex` 9.0 秒 × 毎起動だった（ADR-258）。
                """)
        #expect(Set(restored.map(\.path)) == Set(built.map(\.path)),
                "控えから戻した表が元と違う")
    }

    /// ⚠️ 逆向き（**鈍すぎ**の側）。控えが古いのに使ったら、消えた写真が一覧に残り、
    /// 増えた写真が解析候補に出ない。
    @Test("前の起動のあと写真が増えていたら、控えを使わず作り直す")
    func snapshotIsRejectedWhenPhotosChangedWhileClosed() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1", added: [item("/a.jpg"), item("/b.jpg")],
                               removed: [], newCursor: "c1")
        _ = await first.cachedPhotoRefs()           // 控えが書かれる

        // アプリが閉じている間に差分が入った状況（別の店が書く＝同じ容器）。
        let writer = fx.relaunch()
        await writer.applyDelta(accountId: "acc1", added: [item("/c.jpg")],
                                removed: [], newCursor: "c2")

        let second = fx.relaunch()
        let refs = await second.cachedPhotoRefs()
        #expect(refs.count == 3, "増えた写真が表に出ていない（控えが古い）")
        #expect(await second.itemIndexBuildsForTesting == 1,
                "中身が変わったのに控えをそのまま使った")
    }

    /// ⚠️ 撮影日は控えに**載っている**値。閉じている間に埋まったら作り直すこと
    /// （さもないと並び順と顔の時期グループが古いままになる）。
    @Test("閉じている間に撮影日が埋まったら、控えを使わず作り直す")
    func snapshotIsRejectedWhenCaptureDatesWereFilledWhileClosed() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        _ = await first.cachedPhotoRefs()

        let writer = fx.relaunch()
        _ = await writer.recordCaptureDateProbe(
            path: "/a.jpg", captureDate: Date(timeIntervalSince1970: 1_500_000_000),
            latitude: nil, longitude: nil)

        let second = fx.relaunch()
        let refs = await second.cachedPhotoRefs()
        #expect(await second.itemIndexBuildsForTesting == 1, "撮影日が変わったのに控えを使った")
        #expect(refs.first?.captureDate == Date(timeIntervalSince1970: 1_500_000_000),
                "表の撮影日が古い")
    }

    /// ⚠️ **壊れた控えで起動を止めない**。`Caches` は OS が好きなときに削る。
    @Test("控えが壊れていたら、黙って作り直す")
    func corruptSnapshotFallsBackToRebuilding() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        _ = await first.cachedPhotoRefs()

        let snapshot = fx.dir.appendingPathComponent("item-index.bin")
        #expect(FileManager.default.fileExists(atPath: snapshot.path), "前提: 控えが書かれていない")
        try Data("garbage".utf8).write(to: snapshot)

        let second = fx.relaunch()
        let refs = await second.cachedPhotoRefs()
        #expect(refs.count == 1, "壊れた控えで表が空になった")
        #expect(await second.itemIndexBuildsForTesting == 1, "作り直していない")
    }

    /// ⚠️⚠️ **ADR-257 と ADR-258 の相互作用**（レビューループで見つけた・ADR-260）。
    ///
    /// 控えは「表を**作り直した**回」にしか書いていなかった。ところが撮影日の問い合わせは
    /// 表を作り直さず中身だけ直すので、鍵（未問い合わせ数を含む）は変わるのに控えは古いまま
    /// ——**次の起動で必ず鍵が合わず作り直す**。1 枠 500 枚訊く設計（ADR-257）なので、
    /// 撮影日が埋まり切るまで（実機で約 2 か月）ADR-258 はほとんど効かなかった。
    ///
    /// ⚠️ 2 つの正しい修正が、組み合わせると片方を無効にする——
    /// **単体のテストでは原理的に見つからない**（どちらも単体では通る）。
    @Test("撮影日を訊いたあとでも、次の起動は控えから復元できる")
    func snapshotStaysUsableAfterCaptureDateProbes() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1",
                               added: (0..<20).map { item("/p/\($0).jpg") },
                               removed: [], newCursor: "c1")
        _ = await first.cachedPhotoRefs()           // 表を作る＝控えが書かれる
        #expect(await first.itemIndexBuildsForTesting == 1, "前提: 1 回目は作る")

        // 枠が撮影日を訊いた（表は作り直さず中身だけ変わる＝鍵が動く）。
        for i in 0..<5 {
            _ = await first.recordCaptureDateProbe(
                path: "/p/\(i).jpg",
                captureDate: Date(timeIntervalSince1970: 1_500_000_000 + Double(i)),
                latitude: nil, longitude: nil)
        }
        #expect(await first.itemIndexBuildsForTesting == 1,
                "前提: 問い合わせで表を作り直してはいない（中身だけ直す）")
        // 枠の終わりに控えを書き直す（これが無いと次の起動で作り直しになる）。
        await first.refreshIndexSnapshotIfReady()

        let second = fx.relaunch()
        let refs = await second.cachedPhotoRefs()
        #expect(await second.itemIndexBuildsForTesting == 0, """
                撮影日を訊いたあとの起動で 10.8 万行を歩き直している。
                1 枠 500 枚訊く設計（ADR-257）なので、これだと ADR-258 は
                撮影日が埋まり切るまで（約 2 か月）ほとんど効かない。
                """)
        #expect(refs.count == 20)
        // 控えから戻した表に、訊いた撮影日が入っていること（古い表を使っていない）。
        let probed = refs.filter { $0.captureDate != nil }
        #expect(probed.count == 5, "控えが問い合わせ前の古い中身だった（\(probed.count) 件）")
    }

    /// ⚠️ 表がそろっていないときに書き直しを頼まれても、**作り始めない**
    /// （ここで 9 秒を払ったら本末転倒）。
    @Test("表がまだ無いときの書き直しは、何もしない")
    func refreshDoesNothingWhenTheIndexIsNotLoaded() async throws {
        let fx = try Fixture()
        let store = fx.relaunch()
        await store.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        await store.refreshIndexSnapshotIfReady()
        #expect(await store.itemIndexBuildsForTesting == 0, "書き直しのために表を作り始めた")
        let snapshot = fx.dir.appendingPathComponent("item-index.bin")
        #expect(!FileManager.default.fileExists(atPath: snapshot.path),
                "表が無いのに控えを書いた（空の表を控えると次の起動が空で走る）")
    }

    /// ⚠️⚠️ **控えは「毎起動の作り直し」という自己修復を取り上げる**（ADR-262）。
    ///
    /// 表示に関わる値が変わらなかった問い合わせ（EXIF が無かった写真）は版を進めない
    /// ——それは正しい（進めると 10.8 万件の一覧を作り直す）。だが「訊いた」印を表へ
    /// 移さないと **DB は「訊いた」・表は「まだ」**の食い違いが残る。
    /// 以前は毎起動の作り直しが消していたが、控えを入れた今は**起動を跨いで残る**。
    /// その印は「一覧の日付（アップロード時刻）で上書きしてよいか」の判断に使う。
    ///
    /// ⚠️ **印を直に見る**。`applyDelta` 経由で確かめようとしたら、
    /// 行が変わらない回は表を触らないので**どちらの実装でも通ってしまった**（空振り）。
    /// 観測できる一番近いところを見る。
    @Test("EXIF が無かった写真でも、表の「訊いた」印は立つ")
    func theProbedMarkReachesTheIndexEvenWhenNothingWasFound() async throws {
        let fx = try Fixture()
        let store = fx.relaunch()
        await store.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        _ = await store.cachedPhotoRefs()           // 表を作る
        #expect(await store.indexProbedForTesting(path: "/a.jpg") == false, "前提: まだ訊いていない")

        let changed = await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: nil,
                                                         latitude: nil, longitude: nil)
        #expect(!changed, "前提: 表示に関わる値は変わっていない（この経路を通っていない）")
        #expect(await store.captureDateProbePendingCount() == 0, "前提: DB は「訊いた」")

        #expect(await store.indexProbedForTesting(path: "/a.jpg") == true, """
                DB は「訊いた」なのに表は「まだ」のまま。
                以前は毎起動の作り直しが消していたが、控え（ADR-258）を入れた今は
                起動を跨いで残り、EXIF で確かめた日付が一覧の日付で上書きされ得る。
                """)
    }

    /// ⚠️ 印が控えにも乗ること（表だけ直しても、控えが古ければ次の起動で戻る）。
    @Test("立った「訊いた」印は、控えにも乗って次の起動へ渡る")
    func theProbedMarkSurvivesIntoTheNextLaunch() async throws {
        let fx = try Fixture()
        let first = fx.relaunch()
        await first.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        _ = await first.cachedPhotoRefs()
        _ = await first.recordCaptureDateProbe(path: "/a.jpg", captureDate: nil,
                                               latitude: nil, longitude: nil)
        await first.refreshIndexSnapshotIfReady()

        let second = fx.relaunch()
        _ = await second.cachedPhotoRefs()
        #expect(await second.itemIndexBuildsForTesting == 0, "前提: 控えから戻せていない")
        #expect(await second.indexProbedForTesting(path: "/a.jpg") == true,
                "控えに「訊いた」印が乗っていない（次の起動で食い違いが戻る）")
    }

    /// ⚠️ 控えが**無い**初回起動でも当然動く（控えは最適化であって前提ではない）。
    @Test("控えが無ければ作る（初回起動）")
    func firstLaunchBuildsNormally() async throws {
        let fx = try Fixture()
        let store = fx.relaunch()
        await store.applyDelta(accountId: "acc1", added: [item("/a.jpg")],
                               removed: [], newCursor: "c1")
        #expect(await store.cachedPhotoRefs().count == 1)
        #expect(await store.itemIndexBuildsForTesting == 1)
    }
}
