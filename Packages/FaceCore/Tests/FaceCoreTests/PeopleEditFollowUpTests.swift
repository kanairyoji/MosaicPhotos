import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// 人物の手動修正は、後追い（AI アルバムの掃除＝`onPeopleEdited`）を**待たずに**戻る。
/// 実フィードバック: 人物アルバムで「XX ではない」を選んでも描き直されず、ホームに戻って
/// 入り直すと消えている——掃除（数十秒）の後ろで描き直しが待たされていた。
@Suite("PeopleEngine: 修正の後追いは待たない")
struct PeopleEditFollowUpTests {

    private func signal(_ vec: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(vec), quality: 0.9)
    }

    @MainActor
    final class Counter { var calls = 0; var finished = 0 }

    @Test("removePhoto は後追いの完了を待たず、連続操作の後追いは 1 回にまとまる")
    @MainActor
    func removePhotoReturnsBeforeFollowUp() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0, Float(i) * 0.01])]) }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1)
        let cid = people[0].clusterID

        let engine = PeopleEngine(faceProvider: nil, store: store)
        let counter = Counter()
        engine.onPeopleEdited = {
            counter.calls += 1
            try? await Task.sleep(for: .milliseconds(300))   // 掃除が遅い状況を模す
            counter.finished += 1
        }

        let t0 = Date()
        let removed1 = await engine.removePhoto(itemID: "L-a0", from: cid)
        let removed2 = await engine.removePhoto(itemID: "L-a1", from: cid)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(removed1 == 1 && removed2 == 1)
        // 修正そのものは後追いの 300ms×2 を待たない。
        #expect(elapsed < 0.25, "後追いを待ってしまった: \(elapsed)s")
        #expect(counter.finished == 0, "戻る前に後追いが終わっている＝待っていた")

        await engine.awaitEditFollowUp()
        // 走行中に来た 2 回目は、終わってからもう 1 回だけ（2 回以下・0 回ではない）。
        #expect(counter.calls >= 1 && counter.calls <= 2, "後追いの回数: \(counter.calls)")
        #expect(counter.finished == counter.calls)
        // 修正自体は反映済み。
        let left = await store.memberRefKeys(forPerson: cid)
        #expect(!left.contains("L-a0") && !left.contains("L-a1"))
    }
}
