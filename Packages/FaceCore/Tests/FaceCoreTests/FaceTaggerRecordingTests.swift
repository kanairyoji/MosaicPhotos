import Foundation
import Testing
@testable import FaceCore

/// 「解析できなかった写真を**走査済みとして記録しない**」不変条件（ADR-92）。
///
/// これを破ると、画像が一時的に取れなかっただけの写真が「顔ゼロで走査済み」として確定し、
/// スキャン版を上げるまで二度と見直されない。実際 ADR-90 で解析解像度を上げた直後、
/// 閲覧中に取得を譲ると 256px へフォールバックして低品質のまま記録される経路があった。
@Suite("FaceTagger recording")
struct FaceTaggerRecordingTests {

    /// `detectFaces` の戻り値を差し替えられるスタブ。
    private struct StubProvider: FacePerceptionProvider {
        /// refKey → 返す顔。**辞書にキーが無い＝解析できなかった**（記録してはいけない）。
        let response: [String: [DetectedFaceSignal]]
        var isAvailable: Bool { true }
        func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
            var out: [String: [DetectedFaceSignal]] = [:]
            for key in refKeys {
                if let faces = response[key] { out[key] = faces }
            }
            return out
        }
    }

    private func signal() -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: Data(count: 8), quality: 0.9)
    }

    @MainActor
    private func runScan(response: [String: [DetectedFaceSignal]],
                         candidates: [String]) async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let tagger = FaceTagger(store: store, provider: StubProvider(response: response))
        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true, onBatch: {})
        return store
    }

    @Test("解析できた写真は記録する（顔ゼロでも＝再スキャンしない）")
    @MainActor
    func recordsAnalyzedPhotos() async {
        let store = await runScan(response: ["L-a": [signal()], "L-b": []],
                                  candidates: ["L-a", "L-b"])
        let scanned = await store.scannedRefKeys()
        #expect(scanned == ["L-a", "L-b"])
    }

    /// 回帰: 画像が取れなかった写真（辞書にキーが無い）は**未走査のまま**にする。
    @Test("解析できなかった写真は記録しない（次の窓で拾い直せる）")
    @MainActor
    func doesNotRecordUnanalyzedPhotos() async {
        // "L-b" は応答に含めない＝画像を取得できず解析していない。
        let store = await runScan(response: ["L-a": [signal()]],
                                  candidates: ["L-a", "L-b"])
        let scanned = await store.scannedRefKeys()
        #expect(scanned == ["L-a"], "解析できなかった L-b を走査済みにしてはいけない")
    }

    @Test("全件が解析できなくても走査済みは増えない")
    @MainActor
    func recordsNothingWhenAllUnanalyzed() async {
        let store = await runScan(response: [:], candidates: ["L-a", "L-b", "L-c"])
        let scanned = await store.scannedRefKeys()
        #expect(scanned.isEmpty)
    }
}
