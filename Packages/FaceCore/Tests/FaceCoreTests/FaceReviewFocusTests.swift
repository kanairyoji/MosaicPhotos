import CoreGraphics
import Foundation
import MosaicSupport
import PerceptionCore
import Testing
@testable import FaceCore

/// レビューの候補探索は**注目人物（＝名前を付けた人）を基準にする**（ADR-123）。
///
/// ⚠️ 実フィードバック: 「100 枚単位で名前を付けている人物は数名。数枚しかない名前も付けて
/// いない人物を基準に検討する必要はない」。基準を全人物に取ると探索は人物数²、顔の読み出しは
/// 全顔になり、人物が増えるほど「候補の人を探す」が遅くなる（実機で 5.9 秒）。
@Suite("レビューの基準は注目人物", .serialized)
struct FaceReviewFocusTests {

    /// 直交する埋め込みで人物を作る（別人として必ず分かれる・`ScaleRegressionTests` と同じ流儀）。
    private func makeStore(people: Int, shots: Int = 3) async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for person in 0..<people {
            var vector = [Float](repeating: 0, count: people)
            vector[person] = 1
            for shot in 0..<shots {
                let signal = DetectedFaceSignal(
                    boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                    embedding: ClipMath.encodeHalf(vector), quality: 0.9)
                await store.recordScan(refKey: "L-p\(person)-\(shot)", faces: [signal])
            }
        }
        return store
    }

    /// 人物（クラスタ）の ID を写真枚数の多い順に返す。
    private func clusterIDs(_ store: FaceStore) async -> [Int] {
        await store.clusterCountsForTesting().sorted { $0.value > $1.value }.map(\.key)
    }

    /// しきい値の**少し下**（統合はされないが候補の帯には入る）ベクトルを作る。
    /// ⚠️ 固定値で書くと、しきい値の校正次第で「合流してしまう」か「帯から外れる」になり、
    /// テストが何も見なくなる（fixture が意図した状態か必ず確かめる・ADR-119 の教訓）。
    private func nearVector(dot d: Float, dimensions: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[0] = d
        v[1] = (1 - d * d).squareRoot()
        return v
    }

    /// 「名前つき 1 人＋その候補になる断片＋より大きい無名の人物」のストア。
    private func makeNamedAnchorStore() async -> (store: FaceStore, namedID: Int, fragmentID: Int) {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let thr = await store.calibratedThreshold()
        let near = nearVector(dot: thr - 0.05, dimensions: 4)   // 帯 [thr-0.10, thr) の中
        func record(_ refKey: String, _ v: [Float]) async {
            await store.recordScan(refKey: refKey, faces: [DetectedFaceSignal(
                boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                embedding: ClipMath.encodeHalf(v), quality: 0.9)])
        }
        for i in 0..<3 { await record("L-named\(i)", [1, 0, 0, 0]) }
        for i in 0..<3 { await record("L-frag\(i)", near) }
        for i in 0..<12 { await record("L-big\(i)", [0, 0, 1, 0]) }   // 無名で最大

        // ⚠️ ID の振られ方に前提を置かず、**写真キー**からクラスタを引く。
        let byCluster = await store.memberRefKeysByCluster()
        func cluster(containing prefix: String) -> Int {
            byCluster.first { $0.value.contains { $0.hasPrefix(prefix) } }?.key ?? -1
        }
        return (store, cluster(containing: "L-named"), cluster(containing: "L-frag"))
    }

    /// ⚠️ 「大きい方」ではなく「名前を付けた方」が基準になること。名前は
    /// **ユーザーが関心を表明した唯一の印**なので、枚数より優先する。
    @Test("一括レビューの基準は、より大きい無名の人物ではなく命名済みの人物")
    func anchorPrefersNamedPersonOverBiggerUnnamed() async {
        let (store, namedID, fragmentID) = await makeNamedAnchorStore()
        #expect(namedID >= 0 && fragmentID >= 0 && namedID != fragmentID,
                "fixture が意図した形になっていない（named=\(namedID) fragment=\(fragmentID)）")
        await store.rename(clusterID: namedID, name: "太郎")

        let item = await store.batchReviewItem(minFaces: 1)
        #expect(item?.anchorClusterID == namedID,
                "無名の大きい人物が基準になった（名前を付けた人を優先すること）")
        #expect(item?.candidates.contains { $0.clusterID == fragmentID } == true,
                "帯の中にいる断片が候補に出ていない")
    }

    /// ⚠️ 速くなっただけで質問が出なくなっては意味が無い。**基準に関わる質問は出る**こと。
    @Test("命名済みの人物についてはレビュー候補が出る")
    func stillProducesItemsForNamedPeople() async {
        let (store, namedID, fragmentID) = await makeNamedAnchorStore()
        #expect(namedID >= 0 && fragmentID >= 0, "fixture が意図した形になっていない")
        await store.rename(clusterID: namedID, name: "太郎")

        let items = await store.reviewItems(minFaces: 1, limit: 30)
        #expect(!items.isEmpty, "注目人物についての質問が 1 つも出ない（絞りすぎ）")
    }
}
