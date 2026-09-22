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
    @Test("顔を 4 倍にしても、読み出しは 2 回のまま")
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
        #expect(small.count == 2)
        #expect(large.count == small.count)
    }
}
