import CoreGraphics
import Foundation
import MosaicSupport
import PerceptionCore
import Testing
@testable import FaceCore

/// クラウドの顔の撮影日を後から埋める（ADR-218）。
@Suite("クラウドの顔の撮影日を埋める（ADR-218）", .serialized)
struct CloudCaptureDateFillTests {

    private let shotAt = Date(timeIntervalSince1970: 1_400_000_000)

    private func signal(_ v: [Float], date: Date? = nil) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9, captureDate: date)
    }

    @Test("撮影日が空のクラウドの顔だけが対象になり、分かった分だけ埋まる")
    func fillsOnlyCloudFacesWithKnownDates() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let cloudA = PhotoRef.cloud("/a.jpg").encoded
        let cloudB = PhotoRef.cloud("/b.jpg").encoded
        let cloudDated = PhotoRef.cloud("/c.jpg").encoded
        let local = PhotoRef.local("L1").encoded
        await store.recordScan(refKey: cloudA, faces: [signal([1, 0, 0])])
        await store.recordScan(refKey: cloudB, faces: [signal([0, 1, 0])])
        await store.recordScan(refKey: cloudDated, faces: [signal([0, 0, 1], date: shotAt)])
        await store.recordScan(refKey: local, faces: [signal([1, 1, 0])])

        #expect(await store.cloudPathsMissingCaptureDate() == ["/a.jpg", "/b.jpg"])

        // b は EXIF が無い（分からない）。
        let filled = await store.fillCloudCaptureDates(["/a.jpg": shotAt])
        #expect(filled == 1)
        let dates = await store.captureDatesByRefKeyForTesting()
        #expect(dates[cloudA] == .some(shotAt))
        #expect(dates[cloudB] == .some(nil))
        #expect(dates[local] == .some(nil), "端末写真の顔を触った")
        #expect(await store.cloudPathsMissingCaptureDate() == ["/b.jpg"])
    }

    /// ADR-119: 顔の数に比例して読み出し回数が増えない（数えるのは回数）。
    ///
    /// ⚠️ **2 回 → 1 回になった**（ADR-246）。洗い出し側を使い捨てコンテキストのページ読みへ
    /// 移したので、本体のコンテキストで引くのは「直す顔だけ」の 1 回（chunk）になった。
    /// 期待値を緩めたのではなく**強くなった**——ページ読みを通っているかは
    /// `missingCaptureDateScanUsesPagedReads` が別に見ている。
    @Test("顔を 4 倍にしても、読み出しは 1 回のまま")
    func fetchCountDoesNotGrowWithFaces() async {
        func fetches(photos: Int) async -> (count: Int, filled: Int) {
            let store = FaceStore(isStoredInMemoryOnly: true)
            for i in 0..<photos {
                await store.recordScan(refKey: PhotoRef.cloud("/p\(i).jpg").encoded,
                                       faces: [signal([1, Float(i) * 0.01, 0])])
            }
            // ⚠️ ストアごとに数える（`PerfTrace` は並行する別テストの読み出しも数えてしまう）。
            let before = await store.fetchCountForTesting
            let paths = await store.cloudPathsMissingCaptureDate()
            let filled = await store.fillCloudCaptureDates(
                Dictionary(uniqueKeysWithValues: paths.map { ($0, shotAt) }))
            return (await store.fetchCountForTesting - before, filled)
        }
        let small = await fetches(photos: 10)
        let large = await fetches(photos: 40)
        // ⚠️ fixture の前提: 実際に顔が埋まっている（空振りで通る assert にしない）。
        #expect(small.filled == 10)
        #expect(large.filled == 40)
        #expect(small.count == 1, "本体のコンテキストで引くのは「直す顔だけ」の 1 回で足りる")
        #expect(large.count == small.count, "顔の数に比例して読み出しが増えている")
    }

    /// ⚠️⚠️ **本体のコンテキストに全顔を抱えない**（ADR-246・実機ログ diagnostics-102）。
    ///
    /// 実機では撮影日の埋め直しが **1 ステップで +231MB（575MB → 806MB）**跳ね、背面では
    /// メモリ圧迫で 11 回落とされていた。原因は `captureDate == nil` を本体のコンテキストで
    /// 全件 fetch していたこと——`propertiesToFetch` は列を絞らない（ADR-236）ので、
    /// 埋め込み（1 顔 1KB）ごと実体化し、本体のコンテキストが登録し続ける。
    ///
    /// ⚠️ **回数で見る**（ADR-119）。常駐メモリはテストで測れないが、
    /// 「使い捨てコンテキストのページ読みを通っているか」「本体のコンテキストで全件 fetch して
    /// いないか」は数えられる。
    @Test("撮影日の洗い出しは、使い捨てコンテキストのページ読みを通る")
    func missingCaptureDateScanUsesPagedReads() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<30 {
            await store.recordScan(refKey: PhotoRef.cloud("/photo/\(i).jpg").encoded,
                                   faces: [signal([Float(i), 1, 0])])
        }
        let pagedBefore = await store.pagedFaceRowsForTesting
        let fetchesBefore = await store.fetchCountForTesting

        let paths = await store.cloudPathsMissingCaptureDate()

        let pagedAfter = await store.pagedFaceRowsForTesting
        let fetchesAfter = await store.fetchCountForTesting
        #expect(paths.count == 30, "fixture: 撮影日が空のクラウド写真が集まっていない: \(paths.count)")
        #expect(pagedAfter > pagedBefore, """
            ページ読みを通っていない（本体のコンテキストで全件 fetch している）。
            実機ではこれが 1 ステップ +231MB になり、背面でメモリ圧迫に落とされていた。
            """)
        #expect(fetchesAfter == fetchesBefore, """
            本体のコンテキストで fetch している（\(fetchesAfter - fetchesBefore) 回）。
            読むだけの走査は使い捨てコンテキストに寄せること。
            """)
    }

    /// ⚠️ 書き込み側も同じ。**読みはページ・書きは対象だけ**。
    @Test("埋め直しは、直す顔だけを本体のコンテキストで引く")
    func fillOnlyFetchesTheFacesItChanges() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<30 {
            await store.recordScan(refKey: PhotoRef.cloud("/photo/\(i).jpg").encoded,
                                   faces: [signal([Float(i), 1, 0])])
        }
        let shot = Date(timeIntervalSince1970: 1_400_000_000)
        let fetchesBefore = await store.fetchCountForTesting

        // 30 枚のうち 1 枚だけ日付が分かった。
        let filled = await store.fillCloudCaptureDates(["/photo/7.jpg": shot])

        #expect(filled == 1, "1 枚だけ埋まるはずが \(filled) 枚")
        let fetchesAfter = await store.fetchCountForTesting
        let fetches = fetchesAfter - fetchesBefore
        #expect(fetches <= 2, """
            本体のコンテキストでの fetch が \(fetches) 回。
            直す顔だけを引くなら 1 回（chunk）で足りる——全件を引いていないか。
            """)
    }

    // MARK: - 「訊き直しても答えが同じなら訊かない」（ADR-243）

    /// ⚠️⚠️ **この観点が丸ごと無かった**（実機ログ diagnostics-101）。
    /// 既存のテストは「日付を渡したら顔に入るか」＝**中身の正しさ**だけを見ていた。
    /// ところが実機で問題になったのは**呼ばれる頻度**で、5 時間ぶんまったく同じ行が並んでいた:
    /// ```
    /// faces: cloud capture dates — 空の写真 22061 / 分かった 0 / 埋めた顔 0
    /// ```
    /// 成果ゼロなのに毎時、顔の全走査＋キャッシュ側 45 fetch を払っていた。
    /// 「**正しく動くか**」のテストは、「**無駄に動いていないか**」を一切見ない。
    @Suite("撮影日の埋め直しを走らせる条件（ADR-243）")
    struct CaptureDateFillGateTests {

        @Test("一度も走らせていないなら必ず走る")
        func firstRunAlwaysRuns() {
            #expect(!CaptureDateFillGate.canSkip(progress: 100, scanned: 10,
                                                 lastProgress: nil, lastScanned: nil))
            // 片方だけ覚えている（版の途中で足した）場合も走る＝安全側。
            #expect(!CaptureDateFillGate.canSkip(progress: 100, scanned: 10,
                                                 lastProgress: 100, lastScanned: nil))
            #expect(!CaptureDateFillGate.canSkip(progress: 100, scanned: 10,
                                                 lastProgress: nil, lastScanned: 10))
        }

        @Test("どちらも動いていなければ飛ばす（実機で毎時払っていた分）")
        func skipsWhenNothingMoved() {
            #expect(CaptureDateFillGate.canSkip(progress: 22_061, scanned: 86_771,
                                                lastProgress: 22_061, lastScanned: 86_771))
        }

        @Test("EXIF の知識が進んだら走る（新しい日付が分かり得る）")
        func runsWhenExifProgressed() {
            #expect(!CaptureDateFillGate.canSkip(progress: 22_000, scanned: 86_771,
                                                 lastProgress: 22_061, lastScanned: 86_771))
            // 同期で写真が増えて pending が増えた場合も「動いた」＝走る（向きは問わない）。
            #expect(!CaptureDateFillGate.canSkip(progress: 22_100, scanned: 86_771,
                                                 lastProgress: 22_061, lastScanned: 86_771))
        }

        /// ⚠️ 新しくスキャンした写真には撮影日が空の顔が入るので、こちらも走る理由になる。
        @Test("スキャン済みが増えたら走る")
        func runsWhenMorePhotosScanned() {
            #expect(!CaptureDateFillGate.canSkip(progress: 22_061, scanned: 86_800,
                                                 lastProgress: 22_061, lastScanned: 86_771))
        }
    }
}
