import Foundation
import Testing
@testable import DropboxCore

// MARK: - 一覧の解析（純ロジック）

/// **Dropbox の動画を一覧に載せる**（ADR-282）。
@Suite("Dropbox の動画: 一覧の解析")
struct DropboxVideoParsingTests {

    private func parse(_ json: String) throws -> DeltaPage {
        try DeltaPageParser.parse(Data(json.utf8))
    }

    @Test("スマホ・ガラケー・ビデオカメラ・PC の動画を拾い、大きさを持たせる")
    func picksUpVideosWithSize() throws {
        let page = try parse("""
        {"entries":[
          {".tag":"file","name":"IMG_0001.MOV","path_lower":"/v/img_0001.mov","size":48213000,
           "client_modified":"2024-01-01T00:00:00Z"},
          {".tag":"file","name":"a.mp4","path_lower":"/v/a.mp4","size":10},
          {".tag":"file","name":"keitai.3g2","path_lower":"/v/keitai.3g2","size":20},
          {".tag":"file","name":"cam.MTS","path_lower":"/v/cam.mts","size":30},
          {".tag":"file","name":"old.avi","path_lower":"/v/old.avi","size":40},
          {".tag":"file","name":"photo.jpg","path_lower":"/v/photo.jpg","size":50}
        ],"cursor":"c","has_more":false}
        """)
        let videos = page.added.filter(\.isVideo).map(\.path).sorted()
        #expect(videos == ["/v/a.mp4", "/v/cam.mts", "/v/img_0001.mov", "/v/keitai.3g2", "/v/old.avi"])
        let mov = page.added.first { $0.path == "/v/img_0001.mov" }
        #expect(mov?.video?.byteSize == 48_213_000)
        #expect(mov?.video?.duration == nil, "一覧は media_info を返さない＝長さは後で訊く")
        // ⚠️ 写真に動画の印が付いていないこと（付くと写真が解析から消える）。
        let photo = page.added.first { $0.path == "/v/photo.jpg" }
        #expect(photo != nil && photo?.isVideo == false)
    }

    /// ⚠️ 他の用途と衝突する拡張子は動画にしない（TypeScript の .ts・音楽の .mod）。
    @Test("TypeScript や音楽モジュールを動画として並べない")
    func ignoresAmbiguousExtensions() throws {
        let page = try parse("""
        {"entries":[
          {".tag":"file","name":"index.ts","path_lower":"/code/index.ts"},
          {".tag":"file","name":"song.mod","path_lower":"/music/song.mod"},
          {".tag":"file","name":"notes.txt","path_lower":"/x/notes.txt"}
        ],"cursor":"c","has_more":false}
        """)
        #expect(page.added.isEmpty)
    }

    @Test("拡張子は大文字小文字を問わない")
    func caseInsensitiveExtensions() {
        #expect(DeltaPageParser.mediaKind(forPath: "/a/B.MP4") == .video)
        #expect(DeltaPageParser.mediaKind(forPath: "/a/b.HEIC") == .image)
        #expect(DeltaPageParser.mediaKind(forPath: "/a/b") == nil)
    }

    /// ⚠️ 写真と動画の両方に載る拡張子があると、どちらの表に入るかが経路で変わる。
    @Test("写真と動画の拡張子は重ならない")
    func extensionSetsAreDisjoint() {
        #expect(DeltaPageParser.imageExtensions.isDisjoint(with: DeltaPageParser.videoExtensions))
    }
}

// MARK: - 一覧の取り直し（純ロジック）

@Suite("Dropbox の動画: 一覧の取り直しの判定")
struct CloudListingVersionTests {

    @Test("写真だけの時代に見終えたルートは、1 回だけ取り直す")
    func relistsOnlyOldListings() {
        let scanned = Date()
        #expect(CloudListingVersion.needsRelisting(lastFullScan: scanned, listingVersion: nil))
        #expect(CloudListingVersion.needsRelisting(lastFullScan: scanned, listingVersion: 1))
        #expect(!CloudListingVersion.needsRelisting(lastFullScan: scanned,
                                                    listingVersion: CloudListingVersion.current))
    }

    /// まだ見終えていないなら初回同期が全件を取るので、ここでは言わない（判断を二重にしない）。
    @Test("見終えていないルートには何も言わない")
    func silentBeforeFirstFullScan() {
        #expect(!CloudListingVersion.needsRelisting(lastFullScan: nil, listingVersion: nil))
    }
}

#if canImport(UIKit)

// MARK: - キャッシュ（動画は別の表）

/// **動画は写真の表に入らない**（ADR-282）。写真の表を読む側（解析候補・軽い表・
/// 撮影日の問い合わせ）に動画が紛れ込まないことを、読み手ごとに確かめる。
@Suite("Dropbox の動画: キャッシュ")
struct DropboxVideoCacheTests {

    private let account = "acc"
    private let photo = DropboxFileItem(path: "/c/p.jpg", name: "p.jpg", contentHash: "hp",
                                        captureDate: Date(timeIntervalSince1970: 1_600_000_000))
    private func video(hash: String = "hv", size: Int64 = 1_000) -> DropboxFileItem {
        DropboxFileItem(path: "/c/v.mov", name: "v.MOV", contentHash: hash,
                        captureDate: Date(timeIntervalSince1970: 1_600_000_100),
                        video: DropboxVideoInfo(duration: nil, byteSize: size))
    }

    private func seeded() async -> DropboxCacheStore {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: account, added: [photo, video()], removed: [], newCursor: "c1")
        return cache
    }

    @Test("動画は動画の表に、写真は写真の表に入る")
    func routesByKind() async {
        let cache = await seeded()
        #expect(await cache.cachedItems(accountId: account).map(\.path) == ["/c/p.jpg"])
        let videos = await cache.cachedVideos()
        #expect(videos.map(\.path) == ["/c/v.mov"])
        #expect(videos.first?.isVideo == true, "表から戻した動画に印が無い（写真として扱われる）")
        #expect(videos.first?.video?.byteSize == 1_000)
    }

    @Test("解析候補・軽い表・撮影日の問い合わせに動画が混ざらない")
    func photoReadersNeverSeeVideos() async {
        let cache = await seeded()
        #expect(await cache.cachedPhotoRefs().map(\.path) == ["/c/p.jpg"])
        #expect(await cache.cachedContentHashes().keys.sorted() == ["/c/p.jpg"])
        #expect(await cache.pathsNeedingCaptureDateProbe(limit: 10) == ["/c/p.jpg"])
    }

    /// ⚠️ 解析候補の列挙は「写真の集合が変わったか」で見送りを決める（ADR-250）。
    /// 動画で版が進むと、動画が増えるたびに 8 万件を列挙し直す。
    @Test("動画の増減では写真の集合の版も写真の一覧の版も進まない")
    func videosDoNotBumpPhotoRevisions() async {
        let cache = await seeded()
        let photoSet = await cache.currentPhotoSetRevision()
        let items = await cache.currentItemsRevision()
        let videosBefore = await cache.currentVideosRevision()
        let another = DropboxFileItem(path: "/c/w.mp4", name: "w.mp4", contentHash: "hw",
                                      video: DropboxVideoInfo(duration: nil, byteSize: 5))
        await cache.applyDelta(accountId: account, added: [another], removed: [], newCursor: "c2")
        #expect(await cache.currentPhotoSetRevision() == photoSet)
        #expect(await cache.currentItemsRevision() == items)
        #expect(await cache.currentVideosRevision() != videosBefore, "動画の一覧の版が進んでいない")
    }

    @Test("消えた動画は表から消え、掃除の対象（パスの一覧）にも動画が入る")
    func removalAndPrunePaths() async {
        let cache = await seeded()
        #expect(Set(await cache.cachedPaths()) == ["/c/p.jpg", "/c/v.mov"],
                "掃除の対象に動画が無い＝消えた動画が残り続ける")
        #expect(await cache.cachedItemCount(accountId: account) == 2)
        await cache.applyDelta(accountId: account, added: [], removed: ["/c/v.mov"], newCursor: "c2")
        #expect(await cache.cachedVideos().isEmpty)
        #expect(await cache.cachedItems(accountId: account).count == 1, "写真まで消している")
    }

    @Test("中身が差し替わったら長さを訊き直す・同じなら書かない")
    func hashChangeResetsProbe() async {
        let cache = await seeded()
        await cache.recordVideoProbe(path: "/c/v.mov", duration: 12, captureDate: nil,
                                     latitude: nil, longitude: nil)
        #expect(await cache.pathsNeedingVideoProbe(limit: 10).isEmpty)
        let revision = await cache.currentVideosRevision()
        await cache.applyDelta(accountId: account, added: [video()], removed: [], newCursor: "c2")
        #expect(await cache.currentVideosRevision() == revision, "変わっていない行を書き直している")
        await cache.applyDelta(accountId: account, added: [video(hash: "hv2")], removed: [], newCursor: "c3")
        #expect(await cache.pathsNeedingVideoProbe(limit: 10) == ["/c/v.mov"])
        #expect(await cache.cachedVideos().first?.video?.duration == nil, "古い長さが残っている")
    }

    @Test("キャッシュの全消去で動画も消える")
    func clearAllRemovesVideos() async {
        let cache = await seeded()
        await cache.clearAll(accountId: account)
        #expect(await cache.cachedVideos().isEmpty)
    }
}

// MARK: - ストア（通信・表示）

@Suite("Dropbox の動画: ストア")
@MainActor
struct DropboxVideoStoreTests {

    private let videoPath = "/c/v.mov"

    private func makeStore(_ cache: DropboxCacheStore, stub: StubHTTPClient) -> DropboxPhotoStore {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        auth.credential = DropboxCredential(accessToken: "t", refreshToken: nil,
                                            expiresAt: Date().addingTimeInterval(3600),
                                            accountId: "acc1", connectedAt: Date(),
                                            lastRefreshedAt: nil)
        return DropboxPhotoStore(auth: auth, httpClient: stub, cache: cache)
    }

    private func seeded() async -> DropboxCacheStore {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acc1", added: [
            DropboxFileItem(path: "/c/p.jpg", name: "p.jpg", contentHash: "hp"),
            DropboxFileItem(path: videoPath, name: "v.mov", contentHash: "hv",
                            video: DropboxVideoInfo(duration: nil, byteSize: 9)),
        ], removed: [], newCursor: "c1")
        return cache
    }

    private static func json(_ body: String, status: Int = 200)
        -> @Sendable (URLRequest) -> (Data, URLResponse) {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("写真の一覧に動画は入らず、動画は動画の一覧に入る")
    func listsAreSeparated() async {
        let store = makeStore(await seeded(), stub: StubHTTPClient(responder: StubHTTPClient.status(500)))
        // ⚠️ `loadItems()` を使わない。あれはキャッシュの持ち主（`UserDefaults.standard` の指紋）を
        // 照らし、違えばキャッシュを消す——別のアカウントで `loadItems()` を呼ぶテスト
        // （`DropboxPhotoStoreReflectCoalesceTests`）と並行すると、互いのキャッシュを消し合う。
        await store.refreshItemsFromCache()
        #expect(store.items.map(\.path) == ["/c/p.jpg"])
        #expect(store.videoItems.map(\.path) == [videoPath])
    }

    /// ⚠️ ページを送るたびに隣の動画を丸ごと落とさない。
    @Test("フル画像・原本・先読みの経路は動画で通信しない")
    func fullSizePathsRefuseVideos() async throws {
        let stub = StubHTTPClient(responder: StubHTTPClient.status(200))
        let store = makeStore(await seeded(), stub: stub)
        let video = DropboxFileItem(path: videoPath, name: "v.mov",
                                    video: DropboxVideoInfo(duration: nil, byteSize: 9))
        #expect(await store.fullImage(for: video) == nil)
        #expect(await store.originalImageData(for: video) == nil)
        #expect(await store.originalData(for: video) == nil)
        store.prefetchFullImage(for: video)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stub.recordedRequests().isEmpty, "動画を丸ごと取りに行っている")
    }

    @Test("長さ・撮影日時を get_metadata で取り込む（ミリ秒 → 秒）")
    func probesDuration() async {
        let cache = await seeded()
        let store = makeStore(cache, stub: StubHTTPClient(responder: Self.json("""
        {"name":"v.mov","path_lower":"/c/v.mov",
         "media_info":{".tag":"metadata","metadata":{".tag":"video","duration":12345,
           "time_taken":"2014-05-13T16:53:20Z"}}}
        """)))
        #expect(await store.fillMissingVideoInfo() == 1)
        let video = await cache.cachedVideos().first
        #expect(video?.video?.duration == 12.345)
        #expect(video?.captureDate == Date(timeIntervalSince1970: 1_400_000_000))
        #expect(await cache.pathsNeedingVideoProbe(limit: 10).isEmpty, "訊いた記録が付いていない")
    }

    /// ⚠️ 通信できない間に「訊いた本数」を返すと、前面の穴埋めの輪が同じ動画を延々と訊き直す。
    @Test("通信できなかった回は記録せず、0 を返して輪を止める")
    func failedProbeStopsTheLoop() async {
        let cache = await seeded()
        let store = makeStore(cache, stub: StubHTTPClient(responder: StubHTTPClient.status(500)))
        #expect(await store.fillMissingVideoInfo() == 0)
        #expect(await cache.pathsNeedingVideoProbe(limit: 10) == [videoPath], "失敗を「訊いた」にしている")
    }

    @Test("再生できない形式の逃げ道は、Dropbox の Web のプレビュー")
    func webPreviewURL() {
        let url = DropboxPhotoStore.webPreviewURL(path: "/family/2009/movie.avi", name: "Movie.AVI")
        #expect(url?.absoluteString == "https://www.dropbox.com/home/family/2009?preview=Movie.AVI")
        let root = DropboxPhotoStore.webPreviewURL(path: "/clip.mkv", name: "clip.mkv")
        #expect(root?.absoluteString == "https://www.dropbox.com/home?preview=clip.mkv")
    }
}
#endif
