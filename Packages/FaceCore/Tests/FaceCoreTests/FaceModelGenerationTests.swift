import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// モデル更新の影の世代（ADR-186）: 旧世代を表示に使い続けながら新世代を別コンテナで育て、
/// 網羅が閾値に達したら名前・グループを移して切り替える。**旧世代は消えない**。
@Suite("顔モデルの影の世代", .serialized)
@MainActor
struct FaceModelGenerationTests {

    /// 新モデルのスタブ（ID を宣言する）。refKey ごとに固定の埋め込みを返す。
    private struct NewModelProvider: FacePerceptionProvider {
        var isAvailable: Bool { true }
        var modelID: String { "next-model-v2" }
        var pipelineVersion: Int { 9 }
        func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
            var out: [String: [DetectedFaceSignal]] = [:]
            for key in refKeys {
                // a* は人物 A、b* は人物 B（新空間での埋め込み＝旧世代とは別物でよい）。
                let v: [Float] = key.hasPrefix("L-a") ? [1, 0, 0, 0] : [0, 1, 0, 0]
                out[key] = [DetectedFaceSignal(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                               embedding: ClipMath.encodeHalf(v), quality: 0.9)]
            }
            return out
        }
    }

    private func unit(_ i: Int) -> Data {
        var v = [Float](repeating: 0, count: 4); v[i] = 1; return ClipMath.encodeHalf(v)
    }
    private func signal(_ i: Int) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: unit(i), quality: 0.9)
    }

    /// 旧世代: 人物 A（a1…a5・名前「太郎」）と人物 B（b1…b5・名前「花子」）、グループ「家族」。
    private func makeOldGeneration() async -> FaceStore {
        let old = FaceStore(isStoredInMemoryOnly: true)
        _ = await old.recordScans((1...5).map { ("L-a\($0)", [signal(2)]) } + (1...5).map { ("L-b\($0)", [signal(3)]) })
        let map = await old.memberRefKeysByCluster()
        let aID = map.first { $0.value.contains("L-a1") }!.key
        let bID = map.first { $0.value.contains("L-b1") }!.key
        await old.rename(clusterID: aID, name: "太郎")
        await old.rename(clusterID: bID, name: "花子")
        _ = await old.createPeopleGroup(name: "家族", memberClusterIDs: [aID, bID])
        return old
    }

    @Test("コンテナ名: 既存データの世代は FacesV1 のまま、新しいモデルは Faces-<id>")
    func containerNames() {
        #expect(FaceStore.containerName(for: ModelGeneration.legacyFace) == "FacesV1")
        #expect(FaceStore.containerName(for: "next-model-v2") == "Faces-next-model-v2")
        #expect(FaceStore.containerName(for: "a/b c") == "Faces-a-b-c")
    }

    @Test("スキャンは影の世代へ入り、旧世代は変わらない。網羅が足りなければ切り替えない")
    func scansIntoShadowWithoutTouchingOld() async {
        let old = await makeOldGeneration()
        let shadow = FaceStore(isStoredInMemoryOnly: true)
        let engine = PeopleEngine(faceProvider: NewModelProvider(), store: old, shadowStore: shadow)
        #expect(engine.isMigratingFaceModel)

        // 候補 10 枚のうち 5 枚だけスキャン（網羅 50% < 90%）。
        await engine.tagger.scan(candidateRefKeys: (1...5).map { "L-a\($0)" }, batchSize: 4,
                                 betweenBatchNs: 0, allowSimulator: true, onBatch: {})
        #expect(await shadow.scannedCount() == 5)
        #expect(await old.scannedCount() == 10, "旧世代に書いてはいけない")
        let promoted = await engine.promoteShadowIfReady(candidateCount: 10)
        #expect(!promoted)
        #expect(engine.isMigratingFaceModel)
    }

    @Test("網羅が閾値に達したら切り替え: 名前とグループが移り、旧世代は残る")
    func promotesAndCarriesNamesAndGroups() async {
        let old = await makeOldGeneration()
        let shadow = FaceStore(isStoredInMemoryOnly: true)
        let engine = PeopleEngine(faceProvider: NewModelProvider(), store: old, shadowStore: shadow)
        let candidates = (1...5).map { "L-a\($0)" } + (1...5).map { "L-b\($0)" }
        await engine.tagger.scan(candidateRefKeys: candidates, batchSize: 4,
                                 betweenBatchNs: 0, allowSimulator: true, onBatch: {})
        #expect(await shadow.allClusters().count == 2, "fixture: 新世代で 2 人物になっていない")

        let promoted = await engine.promoteShadowIfReady(candidateCount: 10)
        #expect(promoted)
        #expect(!engine.isMigratingFaceModel)
        #expect(engine.store === shadow, "表示が新世代へ切り替わっていない")

        let names = Set(await shadow.allClusters().compactMap(\.name))
        #expect(names == ["太郎", "花子"], "名前が移っていない")
        let groups = await shadow.allPeopleGroupRecords()
        #expect(groups.map(\.name) == ["家族"])
        #expect(groups.first?.memberClusterIDs.count == 2, "グループのメンバーが名前で結び直されていない")
        // 旧世代は消えていない。
        #expect(await old.scannedCount() == 10)
        #expect(Set(await old.allClusters().compactMap(\.name)) == ["太郎", "花子"])
        #expect(PeopleEngine.activeFaceModelID() == "next-model-v2")
        UserDefaults.standard.removeObject(forKey: PeopleEngine.activeFaceModelKey)
    }
}
