import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// 付帯情報の拡充（photo-info-expansion）: 台帳への往復とカバー選択の美的加点。
@Suite("PhotoSenseInfo (tags v2)", .serialized)
struct PhotoSenseInfoTests {

    @Test("recordTags は OCR・人数・美的スコアを保存し、各クエリで取り出せる")
    func roundtripSenseInfo() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        await store.recordTags([
            (refKey: "L-a", info: PhotoSenseInfo(tags: ["beach", "dog"],
                                                 ocrText: "Narita Airport",
                                                 humanCount: 2, aesthetic: 0.7)),
            (refKey: "L-b", info: PhotoSenseInfo(tags: ["mountain"])),
        ])
        let ocrAll = await store.allOcrTexts()
        #expect(ocrAll == ["L-a": "Narita Airport"])
        let ocr = await store.ocrTexts(forRefKeys: ["L-a", "L-b"])
        #expect(ocr["L-a"] == "Narita Airport")
        #expect(ocr["L-b"] == nil)
        let aes = await store.aesthetics(forRefKeys: ["L-a", "L-b"])
        #expect(aes["L-a"] == 0.7)
        let tags = await store.tags(forRefKeys: ["L-a"])
        #expect(tags["L-a"] == ["beach", "dog"])
        // 版は currentVersion（v2）で記録され、taggedRefKeys に含まれる。
        let tagged = await store.taggedRefKeys()
        #expect(tagged.contains("L-a"))
    }

    @Test("再タグ（recordTags 上書き）でキャプションは消えない")
    func retagKeepsCaption() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        await store.recordTags([(refKey: "L-a", info: PhotoSenseInfo(tags: ["old"]))])
        await store.recordCaptions([(refKey: "L-a", caption: "a dog on the beach")])
        await store.recordTags([(refKey: "L-a", info: PhotoSenseInfo(tags: ["new"], ocrText: "hello"))])
        let captions = await store.captions(forRefKeys: ["L-a"])
        #expect(captions["L-a"] == "a dog on the beach")
        let tags = await store.tags(forRefKeys: ["L-a"])
        #expect(tags["L-a"] == ["new"])
    }

    @Test("pickCoverRef は美的スコアで加点する（お気に入りは超えない）")
    func coverPrefersAesthetic() {
        func photo(_ id: String, favorite: Bool = false) -> EnrichedPhoto {
            EnrichedPhoto(id: id, captureDate: nil, latitude: nil, longitude: nil,
                          placeName: nil, country: nil, isFavorite: favorite, people: [])
        }
        let members = [photo("L-a"), photo("L-b"), photo("L-c")]
        // 美的スコアが最も高い写真がカバーになる。
        #expect(pickCoverRef(members, aesthetics: ["L-b": 0.9, "L-a": 0.1]) == "L-b")
        // お気に入り（+100）は美的スコア（±40）より強い。
        let withFav = [photo("L-a", favorite: true), photo("L-b")]
        #expect(pickCoverRef(withFav, aesthetics: ["L-b": 1.0]) == "L-a")
        // スコアなしは従来どおり（クラッシュしない）。
        #expect(pickCoverRef(members) != nil)
    }

    @Test("pickCoverRef は共有済み・閲覧回数で加点する（お気に入りは超えない）")
    func coverPrefersSharedAndViewed() {
        func photo(_ id: String, favorite: Bool = false) -> EnrichedPhoto {
            EnrichedPhoto(id: id, captureDate: nil, latitude: nil, longitude: nil,
                          placeName: nil, country: nil, isFavorite: favorite, people: [])
        }
        let members = [photo("L-a"), photo("L-b"), photo("L-c")]
        // 共有した写真（+15）が閲覧のみ（上限+10）より優先される。
        let usage = ["L-b": PhotoUsageCounts(viewCount: 0, playCount: 0, shareCount: 2),
                     "L-c": PhotoUsageCounts(viewCount: 30, playCount: 0, shareCount: 0)]
        #expect(pickCoverRef(members, usage: usage) == "L-b")
        // お気に入り（+100）は利用シグナルより強い。
        let withFav = [photo("L-a", favorite: true), photo("L-b")]
        #expect(pickCoverRef(withFav, usage: usage) == "L-a")
    }
}
