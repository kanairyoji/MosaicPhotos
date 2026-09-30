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

    /// 画像が**一切取れない**状況（譲り続け・回線断・取得失敗）を再現し、呼ばれた枚数を数える。
    private final class StarvedProvider: FacePerceptionProvider, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requested = 0
        var isAvailable: Bool { true }
        func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
            lock.lock(); requested += refKeys.count; lock.unlock()
            return [:]   // 何も解析できない
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

    /// ⚠️ 画像が取れない状態が続いても、以前は **todo 全体を空で歩き切って** `finished — scanned=0`
    /// で終わり、次の窓でまた同じことを繰り返していた（実フィードバック「夜間解析が進まなくなった」）。
    /// 連続で空なら原因は続いているので、早めに畳んで窓を無駄にしない（ADR-179）。
    @Test("画像が取れない状態が続いたら、todo を歩き切らずに畳む")
    @MainActor
    func stopsAfterConsecutiveEmptyBatches() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let provider = StarvedProvider()
        let tagger = FaceTagger(store: store, provider: provider)
        let candidates = (0..<200).map { "C-/photo/\($0).jpg" }   // 4 枚 × 50 バッチぶん

        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true, onBatch: {})

        // 3 バッチ（12 枚）で畳む。200 枚すべてを要求していたら旧挙動。
        #expect(provider.requested <= 4 * FaceTagger.maxEmptyBatches,
                "空のまま歩き切っている: \(provider.requested) 枚を要求した")
        #expect(await store.scannedRefKeys().isEmpty, "解析できていないのに記録している")
    }

    /// 途中で画像が取れるようになれば、空の連続は途切れて最後まで進む。
    @Test("空が途切れれば最後まで進む")
    @MainActor
    func continuesWhenImagesReturn() async {
        // 最初の 2 バッチ（8 枚）は取れず、以降は取れる。
        var response: [String: [DetectedFaceSignal]] = [:]
        let candidates = (0..<40).map { "L-p\($0)" }
        for key in candidates.dropFirst(8) { response[key] = [] }
        let store = await runScan(response: response, candidates: candidates)
        #expect(await store.scannedRefKeys().count == 32, "空が途切れた後に進んでいない")
    }

    // MARK: - 「次の窓でまた来る」の側（ADR-243）

    /// ⚠️⚠️ **この観点が丸ごと無かった**（実機ログ diagnostics-101 で 6 時間ぶん空回りしていた）。
    /// 上のテスト群は ADR-92「解析できなかった写真を走査済みにしない」を守っているが、
    /// どれも **scan を 1 回しか回さない**。「記録しない」は 1 回で確かめられても、
    /// 「**次の窓でまた来るか**」は 2 回目が無いと見えない。
    /// 実機では Dropbox が status=200 で 0 バイトのサムネを返す写真が 1 枚あり、永久に候補へ戻って
    /// いた——その 1 枚のために毎回 86,772 件の列挙（約 11 秒）が走っていた。
    @Test("取れなかった写真は数えられる（次の窓で諦められるように）")
    @MainActor
    func countsPhotosThatCouldNotBeLoaded() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let tagger = FaceTagger(store: store, provider: StarvedProvider())

        await tagger.scan(candidateRefKeys: ["C-/photo/broken.jpg"], batchSize: 4,
                          betweenBatchNs: 0, allowSimulator: true, onBatch: {})

        #expect(await store.scanLoadFailureCounts().tracked == 1, """
            取れなかったことを数えていない。数えないと「一時的」と「いつまでも取れない」を
            区別できず、同じ写真が永久に候補へ戻り続ける。
            """)
        #expect(await store.scannedRefKeys().isEmpty, "解析できていないのに記録している（ADR-92）")
    }

    /// ⚠️ ループが**本当に終わる**側。上限に達した写真は候補から外れ、provider に訊きさえしない。
    @Test("上限に達した写真は、もう候補に入らない（provider に訊かない）")
    @MainActor
    func exhaustedPhotosLeaveTheCandidateSet() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<FaceStore.maxScanLoadFailures {
            _ = await store.recordScanLoadFailures(["C-/photo/broken.jpg"], now: now)
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }
        #expect(await store.unreadableRefKeys().count == 1, "fixture: まだ外れていない")

        let provider = StarvedProvider()
        let tagger = FaceTagger(store: store, provider: provider)
        await tagger.scan(candidateRefKeys: ["C-/photo/broken.jpg"], batchSize: 4,
                          betweenBatchNs: 0, allowSimulator: true, onBatch: {})

        #expect(provider.requested == 0, """
            上限に達した写真をまだ取りに行っている（\(provider.requested) 枚）。
            実機ではこれが毎時の 11 秒の列挙とサムネ往復を呼んでいた。
            """)
    }

    /// ⚠️ 逆向き——**取れた写真の記録は残さない**。残すと、たまたま数回譲られた写真が
    /// あとで少し失敗しただけで外れてしまう。
    @Test("取れた写真は失敗の記録を持たない")
    @MainActor
    func successfulPhotosCarryNoFailureRecord() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<2 {
            _ = await store.recordScanLoadFailures(["L-p0"], now: now)
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }
        #expect(await store.scanLoadFailureCounts().tracked == 1, "fixture: 記録が無い")

        let tagger = FaceTagger(store: store, provider: StubProvider(response: ["L-p0": []]))
        await tagger.scan(candidateRefKeys: ["L-p0"], batchSize: 4, betweenBatchNs: 0,
                          allowSimulator: true, onBatch: {})

        #expect(await store.scannedRefKeys() == ["L-p0"], "取れたのに記録していない")
        #expect(await store.scanLoadFailureCounts().tracked == 0,
                "取れたのに失敗の記録が残っている")
    }

    /// ⚠️⚠️ **一度も試していない写真を「取れなかった」と数えない**（ADR-243・自己レビューで気づいた）。
    /// `BackgroundTrickle` は譲りの打ち切り・取り消しで**バッチの途中で抜ける**ので、
    /// `results` は `batch` より短くなる。差分を取って数えると、**試してもいない写真**が
    /// 失敗として積まれる——todo の順番は安定しているので、毎回同じ写真が打ち切り位置に来て
    /// **本物の写真が候補から外れる**。それは「取れない 1 枚のために空回りする」より悪い。
    @Test("譲りで打ち切ったぶんは、失敗として数えない")
    @MainActor
    func doesNotBlamePhotosItNeverTried() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let provider = StarvedProvider()
        let tagger = FaceTagger(store: store, provider: provider)
        let candidates = (0..<8).map { "C-/photo/\($0).jpg" }

        // 譲りっぱなし＋待ち時間 0 ＝ 1 枚も試さずに畳む。
        await tagger.scan(candidateRefKeys: candidates, batchSize: 4, betweenBatchNs: 0,
                          maxPauseNs: 0, allowSimulator: true,
                          shouldPause: { true }, onBatch: {})

        #expect(provider.requested == 0, "fixture: 譲っていない（1 枚でも試している）")
        #expect(await store.scanLoadFailureCounts().tracked == 0, """
            試していない写真を失敗として数えた。この形を許すと、打ち切り位置に来やすい写真が
            5 つの窓で外れる＝本物の写真が黙って解析されなくなる。
            """)
    }
}
