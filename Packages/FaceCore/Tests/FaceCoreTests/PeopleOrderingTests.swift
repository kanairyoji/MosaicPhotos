import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 人物一覧（ピープル）の並び順: **写真数降順**、同数は名前つき優先 → clusterID 昇順で決定的。
/// Swift の sort は非安定なので、同数クラスタだらけのライブラリではタイブレークが無いと
/// リロードのたびに一覧が入れ替わって見える（実フィードバック）。
@Suite("People ordering (写真数順)")
struct PeopleOrderingTests {

    private func signal(_ vec: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(vec), quality: 0.9)
    }

    /// 直交ベクトルで独立クラスタを作る（写真数 = レコード数）。
    private func seed(_ store: FaceStore, prefix: String, vec: [Float], photos: Int) async {
        for i in 0..<photos {
            await store.recordScan(refKey: "L-\(prefix)\(i)", faces: [signal(vec)])
        }
    }

    @Test("写真数の多い人物が先に並ぶ")
    func sortedByPhotoCountDescending() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seed(store, prefix: "small", vec: [1, 0, 0, 0], photos: 3)
        await seed(store, prefix: "big", vec: [0, 1, 0, 0], photos: 8)
        await seed(store, prefix: "mid", vec: [0, 0, 1, 0], photos: 5)
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.map(\.count) == [8, 5, 3], "写真数降順でない: \(people.map(\.count))")
        #expect(people.map(\.displayIndex) == [1, 2, 3], "通し番号は並べ替え後に振る")
    }

    @Test("同数なら名前つきが先・その次は clusterID で決定的")
    func tieBreakIsDeterministic() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seed(store, prefix: "a", vec: [1, 0, 0, 0], photos: 4)
        await seed(store, prefix: "b", vec: [0, 1, 0, 0], photos: 4)
        await seed(store, prefix: "c", vec: [0, 0, 1, 0], photos: 4)
        var people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 3)
        // 真ん中の clusterID に名前を付けると、同数タイの先頭に来る。
        let target = people.map(\.clusterID).sorted()[1]
        await store.rename(clusterID: target, name: "太郎")
        people = await store.peopleClusters(minFaces: 3)
        #expect(people.first?.name == "太郎", "同数タイで名前つきが先頭でない")
        // 残り（未命名・同数）は clusterID 昇順＝リロードしても順序が揺れない。
        let unnamedIDs = people.dropFirst().map(\.clusterID)
        #expect(unnamedIDs == unnamedIDs.sorted(), "同数タイの順序が clusterID で決定的でない")
    }
}
