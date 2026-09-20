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
}
#endif
