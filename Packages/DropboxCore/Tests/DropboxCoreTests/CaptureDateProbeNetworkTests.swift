#if canImport(UIKit)
import CoreLocation
import Foundation
import Testing
@testable import DropboxCore

/// **撮影日時の問い合わせ（通信の側）**（ADR-201）。
///
/// `CaptureDateProbeTests` はキャッシュの側（何を対象に選び、何を記録するか）を見ている。
/// こちらは `files/get_metadata` の応答を**解いて保存するところ**——ここが抜けていると、
/// 「対象は正しく選ぶが、返ってきた日付を取り込めない」状態に気づけない。
///
/// ⚠️ 1 往復で**撮影日時と撮影地の両方**を取る（同じ応答に入っている）。
/// 分けて 2 回叩くと、6.8 万枚では往復が倍になる。
@Suite("撮影日時の問い合わせ（通信）")
@MainActor
struct CaptureDateProbeNetworkTests {

    private let path = "/cloud/a.jpg"
    private let uploadedAt = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11

    private func makeStore(_ cache: DropboxCacheStore,
                           responder: @escaping @Sendable (URLRequest) -> (Data, URLResponse))
        -> DropboxPhotoStore {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        // ⚠️ トークンが無いと `rpc` が認証で落ち、**問い合わせそのものが走らない**
        //（テストが「通信に失敗した回」の経路だけを通り、通っているつもりで何も見ない）。
        auth.credential = DropboxCredential(accessToken: "t", refreshToken: nil,
                                            expiresAt: Date().addingTimeInterval(3600),
                                            accountId: "acc1", connectedAt: Date(),
                                            lastRefreshedAt: nil)
        return DropboxPhotoStore(auth: auth, httpClient: StubHTTPClient(responder: responder),
                                 cache: cache)
    }

    private func seeded() async -> DropboxCacheStore {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acc1",
                               added: [DropboxFileItem(path: path, name: "a.jpg",
                                                       contentHash: "h1", captureDate: uploadedAt)],
                               removed: [], newCursor: "c1")
        return cache
    }

    private static func json(_ body: String, status: Int = 200) -> @Sendable (URLRequest) -> (Data, URLResponse) {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("time_taken と location を 1 往復で取り込む")
    func probeStoresBothDateAndLocation() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json("""
        {"name":"a.jpg","path_lower":"/cloud/a.jpg",
         "media_info":{".tag":"metadata","metadata":{".tag":"photo",
           "location":{"latitude":35.681,"longitude":139.767},
           "time_taken":"2014-05-13T16:53:20Z"}}}
        """))

        let result = await store.probeMediaInfo(for: path)

        let expected = Date(timeIntervalSince1970: 1_400_000_000)
        #expect(result.captureDate == expected, "time_taken を解けていない")
        #expect(result.coordinate?.latitude == 35.681)
        let item = await cache.cachedItems(accountId: "acc1").first
        #expect(item?.captureDate == expected, "取り込んだ撮影日時がキャッシュに入っていない")
        #expect(item?.latitude == 35.681, "同じ往復で取れた撮影地を捨てている")
        #expect(await cache.pathsNeedingCaptureDateProbe(limit: 10).isEmpty,
                "訊いた記録が付いていない（毎回訊き直す）")
    }

    /// ⚠️ **EXIF が無い写真も「訊いた」と記録する**（CLAUDE.md 性能原則 3）。
    /// 記録しないと 6.8 万枚ぶんの往復を毎回繰り返す。
    @Test("media_info が無い応答でも「訊いた」ことは記録する")
    func probeRecordsEvenWithoutMediaInfo() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json(#"{"name":"a.jpg"}"#))

        let result = await store.probeMediaInfo(for: path)

        #expect(result.captureDate == nil)
        #expect(await cache.cachedItems(accountId: "acc1").first?.captureDate == uploadedAt,
                "取れなかったのに既存の日付を消した")
        #expect(await cache.pathsNeedingCaptureDateProbe(limit: 10).isEmpty,
                "無いと分かっている写真を毎回訊き直す")
    }

    /// ⚠️ **通信できなかった回は記録しない**。「無い」と「訊けなかった」は違う——
    /// 記録してしまうと、電波が悪かっただけの写真が永久に未取得のまま残る。
    @Test("通信に失敗した回は記録しない（次回に訊き直す）")
    func networkFailureIsNotRecorded() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json("{}", status: 500))

        _ = await store.probeMediaInfo(for: path)

        #expect(await cache.pathsNeedingCaptureDateProbe(limit: 10) == [path],
                "訊けなかった回を『訊いた』と記録した（その写真は永久に直らない）")
    }

    /// ⚠️ **「そこに無い」は訊けなかったのとは違う**（diagnostics-82）。
    /// 消えた写真のキャッシュ行は候補の先頭（撮影日＝アップロード時刻＝いちばん新しい）に
    /// 居座るので、記録しないと穴埋めが**その 12 件から一歩も進まない**。
    /// 実機では 63 回連続で残り 80,172 件のまま動かず、734 回の 409 を費やした。
    @Test("存在しないパスは『訊いた』と記録する（永久に叩き続けない）")
    func permanentNotFoundIsRecorded() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json(
            #"{"error":{".tag":"path","path":{".tag":"not_found"}},"error_summary":"path/not_found/"}"#,
            status: 409))

        _ = await store.probeMediaInfo(for: path)

        #expect(await cache.pathsNeedingCaptureDateProbe(limit: 10).isEmpty,
                "無いと分かったパスを候補に残した（穴埋めがここで永久に止まる）")
        #expect(await cache.cachedItems(accountId: "acc1").first?.captureDate == uploadedAt,
                "訊けなかっただけで既存の日付を消した")
    }

    /// 穴埋めが**死んだ行に飲まれない**こと（実機の詰まりそのもの）。
    @Test("存在しない写真が先頭にあっても、穴埋めは先へ進む")
    func fillMakesProgressPastMissingFiles() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        // 撮影日が新しい順に候補へ並ぶので、消えた写真（＝アップロード時刻を持つ）が先頭に来る。
        let newest = Date(timeIntervalSince1970: 1_800_000_000)
        let gone = (0..<3).map {
            DropboxFileItem(path: "/gone/\($0).jpg", name: "\($0).jpg",
                            contentHash: "g\($0)", captureDate: newest)
        }
        let alive = (0..<2).map {
            DropboxFileItem(path: "/cloud/\($0).jpg", name: "\($0).jpg",
                            contentHash: "h\($0)", captureDate: uploadedAt)
        }
        await cache.applyDelta(accountId: "acc1", added: gone + alive, removed: [], newCursor: "c1")
        let store = makeStore(cache) { request in
            // ⚠️ JSONEncoder は "/" を "\/" と書く。パスの判定は区切りを含めない
            //（含めると全部が「生きている」側に落ちて、テストが素通りする）。
            let arg = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let missing = arg.contains("gone")
            let body = missing
                ? #"{"error_summary":"path/not_found/"}"#
                : #"{"media_info":{"metadata":{"time_taken":"2014-05-13T16:53:20Z"}}}"#
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: missing ? 409 : 200,
                                    httpVersion: nil, headerFields: nil)!)
        }

        _ = await store.fillMissingCaptureDates(limit: 3)   // 消えた 3 件で 1 巡ぶん
        _ = await store.fillMissingCaptureDates(limit: 3)   // 生きている 2 件へ進めるはず

        let pending = await cache.captureDateProbePendingCount()
        #expect(pending == 0, """
                消えた写真に飲まれて穴埋めが進んでいない（残り \(pending) 件）。
                実機では 63 回連続で残り 80,172 件のまま動かなかった。
                """)
        let filled = await cache.cachedItems(accountId: "acc1")
            .filter { $0.path.hasPrefix("/cloud/") }
        #expect(filled.allSatisfy { $0.captureDate == Date(timeIntervalSince1970: 1_400_000_000) },
                "生きている写真の撮影日が入っていない")
    }

    /// 無意味な日付（1970 等）は弾く——一覧側（`DropboxFileItem`）と同じ規則。
    @Test("意味のない撮影日時は取り込まない")
    func meaninglessDatesAreRejected() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json("""
        {"media_info":{"metadata":{"time_taken":"1970-01-01T00:00:00Z"}}}
        """))

        let result = await store.probeMediaInfo(for: path)

        #expect(result.captureDate == nil, "1970 年を撮影日時として取り込んだ")
        #expect(await cache.cachedItems(accountId: "acc1").first?.captureDate == uploadedAt)
    }

    /// 穴埋めのトリクルが、対象を拾って記録し、**残りが減る**こと。
    @Test("穴埋めは対象を処理して、残りを減らす")
    func fillProcessesPendingItems() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let items = (0..<5).map {
            DropboxFileItem(path: "/cloud/\($0).jpg", name: "\($0).jpg",
                            contentHash: "h\($0)", captureDate: uploadedAt)
        }
        await cache.applyDelta(accountId: "acc1", added: items, removed: [], newCursor: "c1")
        let store = makeStore(cache, responder: Self.json("""
        {"media_info":{"metadata":{"time_taken":"2014-05-13T16:53:20Z"}}}
        """))

        let probed = await store.fillMissingCaptureDates(limit: 3)

        #expect(probed == 3, "上限ぶん処理していない")
        #expect(await cache.captureDateProbePendingCount() == 2, "残りが減っていない")
        #expect(await store.fillMissingCaptureDates(limit: 10) == 2, "続きを処理できていない")
        #expect(await store.fillMissingCaptureDates(limit: 10) == 0, "終わったのに走り続ける")
    }

    // MARK: - 背面の枠から呼ぶとき（ADR-261・レビューループで見つけた）

    /// ⚠️⚠️ **一覧の作り直しは 10.8 万件の実体化**（ADR-90 で footprint 821MB）。
    /// しかも早期 return の条件が「版が同じ **かつ** items が空でない」なので、
    /// **背面では items が空＝必ず素通りして実体化する**。
    /// 前面のついでだけだった頃は items が埋まっていたので起きなかったが、
    /// 枠から呼ぶようにした（ADR-257）とたんに毎窓 10.8 万件になる。
    /// 一覧は画面のためのもので、背面には見ている人が居ない。
    @Test("背面の枠から呼んだら、表示用の一覧を作り直さない")
    func doesNotMaterializeTheDisplayListWhenAskedNotTo() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json("""
            {"media_info":{"metadata":{"time_taken":"2015-05-12T15:50:38Z"}}}
            """))
        let before = await cache.materializeCallsForTesting

        let probed = await store.fillMissingCaptureDates(limit: 5, refreshDisplayList: false)
        #expect(probed == 1, "前提: 問い合わせが走っていない（以降の assert が空振りする）")
        // 記録はされていること（作り直さないのは「表示用の一覧」だけ）。
        #expect(await cache.captureDateProbePendingCount() == 0, "記録まで止めてしまっている")

        // ⚠️⚠️ **待つ長さが足りないと、このテストは空振りする**（自分で踏んだ）。
        // 最初 600ms で書いたら、退行を戻しても通った——間引きの待ち
        // （`currentRefreshInterval` は初回同期中 5 秒）より短く、
        // **どちらの実装でも実体化が起きていなかった**だけだった。
        // だから「作り直す側がちゃんと作り直す時間」を基準にする:
        // 下の `refreshesTheDisplayListInTheForeground` は 2 秒ほどで増える。
        // ここでは**その倍以上**待って、増えないことを確かめる。
        try? await Task.sleep(for: .seconds(6))
        #expect(await cache.materializeCallsForTesting == before, """
                背面なのに 10.8 万件を実体化した（毎窓・ADR-90 の 821MB と同じ経路）。
                """)
    }

    /// ⚠️ 逆向き。前面では作り直すこと（撮影日が変われば並び順が変わる）。
    @Test("前面からは、終わったら一覧を作り直す")
    func refreshesTheDisplayListInTheForeground() async {
        let cache = await seeded()
        let store = makeStore(cache, responder: Self.json("""
            {"media_info":{"metadata":{"time_taken":"2015-05-12T15:50:38Z"}}}
            """))
        let before = await cache.materializeCallsForTesting
        _ = await store.fillMissingCaptureDates(limit: 5)   // 既定＝作り直す
        // 間引き（静かになってから 1 回）の待ちを跨いで確かめる。
        var grew = false
        for _ in 0..<20 where !grew {
            try? await Task.sleep(for: .milliseconds(200))
            grew = await cache.materializeCallsForTesting > before
        }
        #expect(grew, "前面なのに一覧を作り直していない（撮影日が変わっても並びが古いまま）")
    }
}
#endif
