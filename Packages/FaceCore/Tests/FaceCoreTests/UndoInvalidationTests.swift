import Foundation
import Testing
import PerceptionCore
@testable import FaceCore

/// 「戻す先が変わったら控えを捨てる」（ADR-187 の周辺）。
///
/// ⚠️ この規則は**必要な場所が多い**。クラスタ ID と構成を変える経路は
/// 再クラスタ・版上げの全再スキャン・クラウド分の測り直し・モデル世代の切り替え・
/// 断片の吸収・写真が消えたときの掃除と 6 つあり、レビューのたびに
/// **1 か所ずつ漏れが見つかった**（13・14・15 周目）。
/// 捨て忘れると「戻す」が、消えたはずのクラスタを**名前つき・顔ゼロ・重心つき**で
/// 復活させる（次のスキャンで二重に数える）。
@Suite("控えの無効化", .serialized)
@MainActor
struct UndoInvalidationTests {

    /// 掃除の入口は「顔モデルが使えること」を要求するので、使える体のスタブを渡す。
    private struct AvailableProvider: FacePerceptionProvider {
        var isAvailable: Bool { true }
        func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] { [:] }
    }

    private func signal(_ i: Int) -> DetectedFaceSignal {
        var v = [Float](repeating: 0, count: 8); v[i % 8] = 1
        return DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                  embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// 回帰: 写真が消えたときの掃除でも控えを捨てる（15 周目に見つかった漏れ）。
    @Test("写真が消えたときの掃除で、控えを捨てる")
    func pruningMissingPhotosClearsUndo() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let keys = (0..<40).map { "L-a\($0)" }   // 1 枚消すだけ＝安全弁に掛からない割合
        _ = await store.recordScans(keys.enumerated().map { ($0.element, [signal($0.offset)]) })

        let engine = PeopleEngine(faceProvider: AvailableProvider(), store: store)
        await store.beginUndo(label: "テスト用の控え", clusterIDs: [], faceIDs: [])
        await engine.refreshUndoLabel()
        #expect(engine.undoLabel != nil, "fixture: 控えが積まれていない")

        // 1 枚が候補から消えた（削除・同期対象外）。
        _ = await engine.pruneMissingPhotos(candidateRefKeys: Array(keys.dropFirst()))
        #expect(engine.undoLabel == nil,
                "掃除で顔と行が消えたのに「戻す」が残る＝押すと幽霊の人物が復活する")
    }

    /// 掃除が何もしなかった回は、控えを残す（余計に捨てない）。
    @Test("掃除が何もしなければ控えは残る")
    func undoSurvivesWhenNothingWasPruned() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let keys = (0..<40).map { "L-b\($0)" }
        _ = await store.recordScans(keys.enumerated().map { ($0.element, [signal($0.offset)]) })

        let engine = PeopleEngine(faceProvider: AvailableProvider(), store: store)
        await store.beginUndo(label: "テスト用の控え", clusterIDs: [], faceIDs: [])
        await engine.refreshUndoLabel()

        _ = await engine.pruneMissingPhotos(candidateRefKeys: keys)   // 全部そろっている
        #expect(engine.undoLabel != nil, "何も消えていないのに「戻す」を奪った")
    }
}
