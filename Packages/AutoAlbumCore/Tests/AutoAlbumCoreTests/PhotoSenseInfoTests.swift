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

    @Test("allAesthetics はスコア付きだけ返す（未付与は含めない）")
    func allAestheticsFetch() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        await store.recordTags([
            (refKey: "L-high", info: PhotoSenseInfo(tags: [], aesthetic: 0.8)),
            (refKey: "L-low", info: PhotoSenseInfo(tags: [], aesthetic: 0.1)),
            (refKey: "L-none", info: PhotoSenseInfo(tags: ["untagged-score"])),   // aesthetic nil
        ])
        let all = await store.allAesthetics()
        #expect(all == ["L-high": 0.8, "L-low": 0.1])
    }

    @Test("適応しきい値: 上位20%を [floor, ceiling] にクランプ")
    func adaptiveThreshold() {
        // 低スコア寄りの分布（日常写真）: 上位20% 境界 0.12 → floor 0.2 へ引き上げ。
        let low = [Double](repeating: -0.1, count: 80) + [Double](repeating: 0.12, count: 20)
        #expect(PhotoQuality.adaptiveThreshold(scores: low) == PhotoQuality.thresholdFloor)
        // 標準的な分布: 上位20% 境界 0.4 がそのまま使われる。
        let mid = [Double](repeating: 0.0, count: 80) + [Double](repeating: 0.4, count: 20)
        #expect(PhotoQuality.adaptiveThreshold(scores: mid) == 0.4)
        // 粒ぞろい（全部高スコア）: ceiling 0.6 で頭打ち＝20% より多く通す。
        let high = [Double](repeating: 0.9, count: 100)
        #expect(PhotoQuality.adaptiveThreshold(scores: high) == PhotoQuality.thresholdCeiling)
        // 空は ceiling（何も通さない側）。
        #expect(PhotoQuality.adaptiveThreshold(scores: []) == PhotoQuality.thresholdCeiling)
    }

    @Test("再タグ（recordTags 上書き）でタグと OCR が更新される")
    func retagUpdatesRecord() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        await store.recordTags([(refKey: "L-a", info: PhotoSenseInfo(tags: ["old"]))])
        await store.recordTags([(refKey: "L-a", info: PhotoSenseInfo(tags: ["new"], ocrText: "hello"))])
        let tags = await store.tags(forRefKeys: ["L-a"])
        #expect(tags["L-a"] == ["new"])
        let ocr = await store.ocrTexts(forRefKeys: ["L-a"])
        #expect(ocr["L-a"] == "hello")
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

    @Test("進捗の分子は「台帳の写真のうちタグ付け済み」——削除済みの記録は数えない")
    func taggedCountAmongLedgerKeys() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        await store.recordTags([
            (refKey: "L-a", info: PhotoSenseInfo(tags: ["beach"])),
            (refKey: "L-b", info: PhotoSenseInfo(tags: ["dog"])),
            (refKey: "L-deleted", info: PhotoSenseInfo(tags: ["old"])),   // 台帳から消えた写真の記録
        ])
        let ledger = ["L-a", "L-b", "L-c"]   // c は未タグ
        #expect(await store.taggedCount(among: ledger) == 2)
        #expect(await store.taggedCount() == 3, "記録の総数は 3＝分子に使うと 3/3 で嘘になる")
    }
}
