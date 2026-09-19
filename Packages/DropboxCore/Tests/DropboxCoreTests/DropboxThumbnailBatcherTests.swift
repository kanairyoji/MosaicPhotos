#if canImport(UIKit)
import Foundation
import MosaicSupport
import Testing
import UIKit
@testable import DropboxCore

/// `DropboxThumbnailBatcher` のバッチ集約・dedup・キャンセル耐性・異常系を、
/// ネットワークをスタブ化して検証する。サムネイル表示不具合の回帰ガード。
@Suite("DropboxThumbnailBatcher")
@MainActor
struct DropboxThumbnailBatcherTests {

    // MARK: - Fixtures

    private func makeAuth() -> DropboxAuthService {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "scheme://cb")
        // expiresAt=nil, refreshToken=nil → freshAccessToken はネットワークなしでトークンを返す。
        auth.setCredentialForTesting(DropboxCredential(
            accessToken: "test-token", refreshToken: nil, expiresAt: nil,
            accountId: "acc", connectedAt: Date(), lastRefreshedAt: nil
        ))
        return auth
    }

    private func makeBatcher(
        _ stub: StubHTTPClient,
        chunkSize: Int = 25,
        debounceNs: UInt64 = 5_000_000
    ) -> DropboxThumbnailBatcher {
        let apiClient = DropboxAPIClient(httpClient: stub, tokenProvider: makeAuth())
        return DropboxThumbnailBatcher(
            apiClient: apiClient,
            cache: DropboxCacheStore(isStoredInMemoryOnly: true),
            debounceNs: debounceNs,
            chunkSize: chunkSize
        )
    }

    private func item(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
    }

    /// バッチリクエストの entries に含まれるパス一覧を取り出す。
    private func paths(in request: URLRequest) -> [String] {
        struct Entry: Decodable { let path: String }
        struct Arg: Decodable { let entries: [Entry] }
        let arg = try? JSONDecoder().decode(Arg.self, from: request.httpBody ?? Data())
        return arg?.entries.map(\.path) ?? []
    }

    /// 記録リクエスト数が `untilCount` に達するまでポーリングで待つ。
    /// 並列 @MainActor テストの競合下でも安定するよう、固定 sleep ではなく結果駆動で待つ。
    private func pollRequests(_ stub: StubHTTPClient, untilCount: Int, maxWaitMs: Int = 2000) async -> [URLRequest] {
        var reqs = await stub.recordedRequests()
        var elapsed = 0
        while reqs.count < untilCount && elapsed < maxWaitMs {
            try? await Task.sleep(nanoseconds: 25_000_000)
            elapsed += 25
            reqs = await stub.recordedRequests()
        }
        return reqs
    }

    // MARK: - Tests

    @Test("同一パスの同時要求は1回だけフェッチし、両方の呼び出しに画像を配送する")
    func deduplicatesSamePath() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        async let a = batcher.thumbnail(for: item("/x.jpg"))
        async let b = batcher.thumbnail(for: item("/x.jpg"))
        let (ra, rb) = await (a, b)

        #expect(ra != nil)
        #expect(rb != nil)
        let reqs = await stub.recordedRequests()
        #expect(reqs.count == 1)
        #expect(paths(in: reqs[0]) == ["/x.jpg"])
    }

    @Test("25件超は1リクエストあたり最大 chunkSize 件に分割し全件取得する")
    func splitsIntoChunks() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub, chunkSize: 25)

        await withTaskGroup(of: UIImage?.self) { group in
            for i in 0..<30 {
                group.addTask { @MainActor in await batcher.thumbnail(for: self.item("/p\(i).jpg")) }
            }
            for await _ in group {}
        }

        let reqs = await stub.recordedRequests()
        let allPaths = reqs.flatMap { paths(in: $0) }
        #expect(Set(allPaths).count == 30)                    // 全件取得
        #expect(reqs.allSatisfy { paths(in: $0).count <= 25 }) // 各リクエスト ≤ 25
    }

    @Test("呼び出し元 Task をキャンセルしても fetch は完走する（キャンセル耐性）")
    func fetchSurvivesCancellation() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        // debounce を長めにして、flush 前にキャンセルできる窓を作る。
        let batcher = makeBatcher(stub, debounceNs: 60_000_000)

        let task = Task { @MainActor in await batcher.thumbnail(for: item("/c.jpg")) }
        try? await Task.sleep(nanoseconds: 5_000_000)   // enqueue は済んでいる
        task.cancel()
        let result = await task.value
        #expect(result == nil)                          // キャンセルされた待機者は nil

        // debounce 経過後に fetch が実行されることをポーリングで確認（pendingItems は残っている）。
        let reqs = await pollRequests(stub, untilCount: 1)
        #expect(reqs.count == 1)
        #expect(reqs.first.map { paths(in: $0) } == ["/c.jpg"])
    }

    @Test("HTTP エラー時は nil を返してハングしない")
    func httpErrorDeliversNil() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.status(500))
        let batcher = makeBatcher(stub)
        let result = await batcher.thumbnail(for: item("/e.jpg"))
        #expect(result == nil)
    }

    @Test("複数の異なるパスはまとめて取得し、各呼び出しに配送する")
    func deliversToMultipleWaiters() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        async let a = batcher.thumbnail(for: item("/a.jpg"))
        async let b = batcher.thumbnail(for: item("/b.jpg"))
        let (ra, rb) = await (a, b)

        #expect(ra != nil)
        #expect(rb != nil)
        let reqs = await stub.recordedRequests()
        #expect(reqs.count == 1)
        #expect(Set(paths(in: reqs[0])) == ["/a.jpg", "/b.jpg"])
    }

    // MARK: - 取り残しレース（機内モード相当）

    /// 混在バッチ（失敗エントリ＋大きい成功エントリ）で、失敗分の nil 配送後・inFlight 解除前の
    /// suspension 窓（成功分のデコード/キャッシュ書き込み中）に同一パスの再要求が来ると、
    /// 待機者が配送済みチャンクを待ち続けて永久スピナーになるレースの回帰テスト。
    /// 修正（チャンク完了時に取り残し待機者を掃き出す）が無いとタイムアウトで失敗する。
    @Test("配送後・inFlight解除前に来た再要求が取り残されない")
    func lateWaiterDuringInFlightWindowResolves() async {
        // 成功側は大きめの画像にして、デコード＋保存の suspension 窓を再要求より確実に長くする。
        let bigBase64 = Self.largePNGBase64
        let stub = StubHTTPClient(responder: { request in
            struct Entry: Decodable { let path: String }
            struct Arg: Decodable { let entries: [Entry] }
            let reqPaths = (try? JSONDecoder().decode(Arg.self, from: request.httpBody ?? Data()))?
                .entries.map(\.path) ?? []
            let entriesJSON = reqPaths.map { p in
                p.contains("fail") ? "{\".tag\":\"failure\"}"
                                   : "{\".tag\":\"success\",\"thumbnail\":\"\(bigBase64)\"}"
            }.joined(separator: ",")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (Data("{\"entries\":[\(entriesJSON)]}".utf8), resp)
        })
        let batcher = makeBatcher(stub)

        async let failing: UIImage? = batcher.thumbnail(for: item("/x/fail.jpg"))
        async let big: UIImage? = batcher.thumbnail(for: item("/x/big.jpg"))
        // 失敗分は成功分のデコードより先に nil 配送される。
        let first = await failing
        #expect(first == nil)

        // この時点でチャンクは成功分のデコード/保存中＝ /x/fail.jpg は inFlight のまま。
        // ここで来る再要求（セルの再構成・リトライ相当）が取り残されず解決されること。
        // ⚠️ 上限は**大きく**取る。取り残しのバグは「永久に返らない」形なので、上限を伸ばしても
        // 検出力は落ちない。一方で 1800×1800 のデコードは遅いマシンで数秒かかり、3 秒では
        // CI が偽陽性で赤くなる（実測: GitHub Actions のシミュレータで失敗・ローカルは通る）。
        let resolved = await resolvesWithinTimeout(ms: 20_000) {
            _ = await batcher.thumbnail(for: self.item("/x/fail.jpg"))
        }
        #expect(resolved, "inFlight 窓中の再要求が配送されず取り残された")
        _ = await big
    }

    /// `op` が指定時間内に完了すれば true。タイムアウト時は op の Task をキャンセルして false。
    private func resolvesWithinTimeout(ms: Int, _ op: @escaping @MainActor () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await op(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// デコードに数十 ms かかる程度の PNG（1800×1800・縞模様）。suspension 窓を広げるための素材。
    private static let largePNGBase64: String = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side: CGFloat = 1800
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { ctx in
            for i in 0..<18 {
                UIColor(hue: CGFloat(i) / 18, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: CGFloat(i) * 100, width: side, height: 100))
            }
        }
        return image.pngData()!.base64EncodedString()
    }()
}

/// diagnostics-81 の回帰: **解析のサムネ取得が「UI が忙しい」を名乗らない**こと。
///
/// 以前は解析（顔・タグ・CLIP）が表示用と同じ経路で取りに行き、そのドレインが
/// `cloudThumbnailBusy` を立てていた。その印は `BackgroundYield.shouldYield()` に
/// 直結しているので、**解析が自分の取得で自分を止める**状態だった（処理枠で埋め込み 0 枚）。
@Suite("サムネ取得の目的（表示 / 解析）")
@MainActor
struct ThumbnailPurposeTests {

    private func makeAuth() -> DropboxAuthService {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "scheme://cb")
        auth.setCredentialForTesting(DropboxCredential(
            accessToken: "test-token", refreshToken: nil, expiresAt: nil,
            accountId: "acc", connectedAt: Date(), lastRefreshedAt: nil))
        return auth
    }

    private func makeBatcher(_ stub: StubHTTPClient, chunkSize: Int = 25,
                            debounceNs: UInt64 = 5_000_000) -> DropboxThumbnailBatcher {
        DropboxThumbnailBatcher(
            apiClient: DropboxAPIClient(httpClient: stub, tokenProvider: makeAuth()),
            cache: DropboxCacheStore(isStoredInMemoryOnly: true),
            debounceNs: debounceNs,
            chunkSize: chunkSize)
    }

    private func item(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
    }

    @Test("解析の要求は「UI が忙しい」を名乗らない／表示の要求は名乗る")
    func uiBusyClaimFollowsDisplayOnly() {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        batcher.enqueueForTesting(item("/analysis-1.jpg"), purpose: .analysis)
        batcher.enqueueForTesting(item("/analysis-2.jpg"), purpose: .analysis)
        #expect(batcher.claimsUIBusyForTesting == false,
                "解析の取得が UI ビジーを名乗っている＝解析が自分の取得で自分を止める（diagnostics-81）")

        batcher.enqueueForTesting(item("/display.jpg"), purpose: .display)
        #expect(batcher.claimsUIBusyForTesting, "表示の取得で UI ビジーが立たない＝背景処理が譲らなくなる")
    }

    @Test("先読み中の写真を解析が要求しても、同じウェーブに二重に入らない（レビュー指摘）")
    func analysisDoesNotDuplicateAPrefetchedPath() {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        batcher.enqueueForTesting(item("/dup.jpg"), purpose: .prefetchForTesting)
        batcher.enqueueForTesting(item("/dup.jpg"), purpose: .analysis)
        let order = batcher.nextWavePathsForTesting()

        #expect(order.filter { $0 == "/dup.jpg" }.count == 1,
                "同じ path が 1 リクエストに 2 回入り、配送も 2 回走る")
    }

    @Test("解析が積んだ写真を後から先読みしても二重にならない（逆順・レビュー指摘）")
    func prefetchDoesNotDuplicateAnAnalysisPath() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        // ⚠️ ドレインを走らせない（デバウンスを十分長く取る）。走ると path が inFlight へ移り、
        //    ウェーブが空になって**バグがあっても通る**テストになる（前版はこれでフレーキーだった）。
        let batcher = makeBatcher(stub, debounceNs: 10_000_000_000)

        batcher.enqueueForTesting(item("/dup2.jpg"), purpose: .analysis)
        // スクロールで先読みが来る。`/other.jpg` は解析に無いので必ず積まれる＝
        // これが見えたら「先読みの処理が終わった」と判定できる（固定 sleep にしない）。
        batcher.prefetch([item("/dup2.jpg"), item("/other.jpg")])
        for _ in 0..<200 where !batcher.pendingPathsForTesting().prefetch.contains("/other.jpg") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let pools = batcher.pendingPathsForTesting()
        // ⚠️ 番兵が本当に積まれたことを確かめる（レビュー指摘・repo 規約「空でも通る assert を
        //    書かない」）。prefetch が何も積まなくなると、下の 2 つは自動的に真になってしまう。
        #expect(pools.prefetch.contains("/other.jpg"), "先読みが機能していない＝この検証は無意味")
        #expect(pools.analysis == ["/dup2.jpg"])
        #expect(pools.prefetch.contains("/dup2.jpg") == false,
                "解析プールに居る path が先読みにも積まれている＝1 リクエストに 2 回入る")

        let order = batcher.nextWavePathsForTesting()
        #expect(order.filter { $0 == "/dup2.jpg" }.count == 1)
    }

    @Test("解析が始めた取得を可視セルが待つときも UI ビジーを名乗る（レビュー指摘）")
    func visibleWaiterOnAnalysisFetchClaimsUIBusy() {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        // 解析が取得を始めた（＝inFlight）状態を作る。
        batcher.enqueueForTesting(item("/shared.jpg"), purpose: .analysis)
        _ = batcher.nextWavePathsForTesting()          // inFlight へ移す
        #expect(batcher.claimsUIBusyForTesting == false, "解析だけなら名乗らない")

        // そこへ可視セルの要求が来たら、取得中でも UI ビジーになる。
        batcher.enqueueForTesting(item("/shared.jpg"), purpose: .display)
        #expect(batcher.claimsUIBusyForTesting,
                "人が見ているサムネを待っているのに、背景処理が譲らなくなる")
    }

    @Test("ウェーブの取り出し順は 表示 → 解析 → 先読み（人が見ている方を待たせない）")
    func waveOrderIsDisplayThenAnalysisThenPrefetch() {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        // 解析を先に積んでも、表示が先に出ること（順番は到着順ではなく優先度で決まる）。
        batcher.enqueueForTesting(item("/a-analysis.jpg"), purpose: .analysis)
        batcher.enqueueForTesting(item("/b-display.jpg"), purpose: .display)
        let order = batcher.nextWavePathsForTesting()

        #expect(order.first == "/b-display.jpg", "解析が表示より先に取り出されている（グリッドが待たされる）")
        #expect(order.contains("/a-analysis.jpg"), "解析の要求が落ちている")
    }
}
#endif
