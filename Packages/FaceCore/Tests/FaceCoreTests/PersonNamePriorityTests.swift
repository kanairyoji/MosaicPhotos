import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 統合・束ねで**付けた名前が消えない**こと（ADR-94）。
/// 実フィードバック「複数のグループを束ねたら、折角つけた名前が消えることがある」への回帰テスト。
@Suite("Person name priority")
struct PersonNamePriorityTests {

    private func signal(_ vec: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(vec), quality: 0.9)
    }

    /// 別写真・別方向の埋め込みで 2 クラスタを作る（同一写真ガードに触れない）。
    private func seedTwoClusters(_ store: FaceStore) async -> (a: Int, b: Int) {
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 2, "前提: 2 クラスタに分かれていること")
        return (people[0].clusterID, people[1].clusterID)
    }

    @Test("統合: 名前がある側の名前を残す（未命名側へ統合しても消えない）")
    func mergeKeepsNamedSide() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let (a, b) = await seedTwoClusters(store)
        await store.rename(clusterID: a, name: "太郎")     // a に名前・b は未命名
        _ = await store.mergeClusters(from: a, into: b)     // **未命名の b へ**統合する
        let people = await store.peopleClusters(minFaces: 1)
        #expect(people.compactMap(\.name).contains("太郎"), "名前つき側の名前が失われた")
    }

    @Test("束ね: 名前つきクラスタが主になる（表示名が消えない）")
    func groupingPrefersNamedCluster() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let (a, b) = await seedTwoClusters(store)
        await store.rename(clusterID: a, name: "太郎")
        await store.linkClusters([a, b])
        let people = await store.peopleClusters(minFaces: 1)
        #expect(people.count == 1, "束ねたので 1 人物になる")
        #expect(people.first?.name == "太郎")
    }

    @Test("束ね: 名前の衝突を検出する（0〜1 件なら確認不要）")
    func detectsNameConflict() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let (a, b) = await seedTwoClusters(store)
        #expect(await store.conflictingNames(in: [a, b]).isEmpty)

        await store.rename(clusterID: a, name: "太郎")
        #expect(await store.conflictingNames(in: [a, b]) == ["太郎"])   // 1 件＝確認不要

        await store.rename(clusterID: b, name: "花子")
        #expect(Set(await store.conflictingNames(in: [a, b])) == ["太郎", "花子"])
    }

    @Test("束ね: 選んだ名前で全クラスタを揃える（表示名が入れ替わらない）")
    func unifyNameAppliesToAll() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let (a, b) = await seedTwoClusters(store)
        await store.rename(clusterID: a, name: "太郎")
        await store.rename(clusterID: b, name: "花子")

        await store.unifyName("太郎", in: [a, b])
        #expect(await store.conflictingNames(in: [a, b]) == ["太郎"])

        await store.linkClusters([a, b])
        let people = await store.peopleClusters(minFaces: 1)
        #expect(people.first?.name == "太郎")
    }

    @Test("人物一覧は写真の多い順に並ぶ")
    func peopleSortedByPhotoCount() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-few\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<6 { await store.recordScan(refKey: "L-many\(i)", faces: [signal([0, 1, 0])]) }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.map(\.count) == [6, 3], "写真の多い順になっていない")
        #expect(people.map(\.displayIndex) == [1, 2], "通し番号は並べ替え後に振る")
    }
}
