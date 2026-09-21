import Foundation
import Testing
@testable import FaceCore

/// **「終わった」と「始められなかった」を区別できるか**（ADR-207）。
///
/// 顔の残数は長いあいだ「スキャン中しか意味を持たない値」で、止まると 0 に戻っていた。
/// おかげで**残作業を抱えたまま「すべて解析済み」と表示**し、OS には成功を返していた。
/// 夜間の窓も同じ値を読んでいたので、顔の残作業を常に 0 と測り、埋め込みが空の窓に
/// アルバム生成が入って共倒れ（diagnostics-72）が再発し得た。
@Suite("顔の残作業（スキャンしていなくても答えられるか）")
struct FaceBacklogTests {

    private struct StubProvider: FacePerceptionProvider {
        let response: [String: [DetectedFaceSignal]]
        var isAvailable: Bool { true }
        func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
            refKeys.reduce(into: [:]) { out, key in
                if let faces = response[key] { out[key] = faces }
            }
        }
    }

    private func signal() -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: Data(count: 8), quality: 0.9)
    }

    /// ⚠️ **これが本丸**。譲って畳んだ回に 0 を返すと、呼び出し側は「終わった」としか読めない。
    @Test("途中で譲って畳んだら、本当の残りを返す（0 で終わらない）")
    @MainActor
    func reportsTrueRemainingWhenPaused() async {
        let candidates = (0..<12).map { "L-\($0)" }
        let response = Dictionary(uniqueKeysWithValues: candidates.map { ($0, [signal()]) })
        let store = FaceStore(isStoredInMemoryOnly: true)
        let tagger = FaceTagger(store: store, provider: StubProvider(response: response))

        // 4 枚処理したところで譲る（前面復帰・生成との相互排他と同じ合図）。
        var processed = 0
        var backlog: (todo: Int, deferred: Int)?
        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true,
                          shouldPause: { processed >= 4 },
                          onProgress: { processed = 12 - $0 },
                          onBacklog: { backlog = ($0, $1) },
                          onBatch: {})

        #expect(backlog?.todo ?? -1 > 0, """
                譲って畳んだのに残りを 0 と報せた（実際は \(12 - processed) 枚残っている）。
                呼び出し側はこれを「すべて解析済み」と読む。
                """)
        let scanned = await store.scannedRefKeys().count
        #expect(scanned < 12, "前提: 全部は終わっていない")
        #expect(backlog?.todo == 12 - scanned, "残りの数が実際と合っていない")
    }

    @Test("全部終わったら 0 を返す")
    @MainActor
    func reportsZeroWhenActuallyFinished() async {
        let candidates = ["L-a", "L-b"]
        let store = FaceStore(isStoredInMemoryOnly: true)
        let tagger = FaceTagger(store: store,
                                provider: StubProvider(response: ["L-a": [], "L-b": [signal()]]))
        var backlog: (todo: Int, deferred: Int)?
        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true, onBacklog: { backlog = ($0, $1) }, onBatch: {})

        #expect(backlog?.todo == 0, "終わったのに残りがあると報せた")
        #expect(backlog?.deferred == 0)
    }

    /// ⚠️ **回線待ちで外したぶんも残作業**（ADR-207）。Wi-Fi の無い端末で端末内写真を
    /// 配り終えると、今回の対象（`todo`）は空になる——クラウドの顔は残っているのに
    /// 「もう無い」と読めてしまう。
    @Test("回線待ちで外したクラウド分を、残作業として数える")
    @MainActor
    func countsCloudPhotosDeferredByTheNetwork() async {
        let candidates = ["L-a", "C-x", "C-y"]
        let store = FaceStore(isStoredInMemoryOnly: true)
        let tagger = FaceTagger(store: store, provider: StubProvider(response: ["L-a": []]))
        var backlog: (todo: Int, deferred: Int)?

        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true,
                          networkAllowed: { false },        // Wi-Fi 待ち
                          onBacklog: { backlog = ($0, $1) }, onBatch: {})

        #expect(backlog?.todo == 0, "端末内写真は終わっている")
        #expect(backlog?.deferred == 2, """
                回線待ちで外したクラウド 2 枚を数えていない（実際は \(backlog?.deferred ?? -1)）。
                これを落とすと、Wi-Fi の無い端末で「すべて解析済み」と出る。
                """)
    }

    /// 走らせずに測れること（スキャンが始められなかった回のため）。
    @Test("スキャンせずに残作業を測れる・測るのは一度だけ")
    @MainActor
    func measuresWithoutScanning() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScans([(refKey: "L-a", faces: [])])
        let pending = await store.pendingCount(candidateRefKeys: ["L-a", "L-b", "L-c"])
        #expect(pending == 2, "走査済みを差し引けていない")
    }
}
