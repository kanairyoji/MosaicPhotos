import Foundation
import Testing
@testable import AutoAlbumCore

/// P2: LLM 審査の純ロジック（多数決・証拠行・プローブ差し替え）。
@Suite("AlbumVerifier (majority / evidence / refine)")
struct AlbumVerifierTests {

    @Test("多数決: drop が keep を上回るときだけ drop（同数・不明は keep＝安全側）")
    func majorityRules() {
        #expect(majorityVerdict([.drop]) == .drop)
        #expect(majorityVerdict([.keep]) == .keep)
        #expect(majorityVerdict([.unsure]) == .unsure)
        #expect(majorityVerdict([.unsure, .drop, .drop]) == .drop)
        #expect(majorityVerdict([.unsure, .drop, .keep]) == .keep)     // 同数 → keep
        #expect(majorityVerdict([.drop, .keep, .keep]) == .keep)
        #expect(majorityVerdict([]) == .unsure)
    }

    @Test("証拠行: 日付・場所・顔数・タグ・キャプションを 1 行に")
    func evidenceLineFormat() {
        let photo = EnrichedPhoto(id: "L-x", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                                  latitude: nil, longitude: nil, placeName: "沖縄県")
        let line = AIAlbumSearcher.evidenceLine(index: 3, photo: photo,
                                                tags: ["beach", "outdoor"],
                                                caption: "A sandy beach at sunset.",
                                                faceCount: 0)
        #expect(line.hasPrefix("3) | 2023-11-1"))   // TZ により 14/15 日どちらか
        #expect(line.contains("沖縄県"))
        #expect(line.contains("faces=0"))
        #expect(line.contains("tags: beach, outdoor"))
        #expect(line.contains("caption: A sandy beach at sunset."))
    }

    @Test("証拠行: 欠けている情報は出さない")
    func evidenceLineOmitsMissing() {
        let photo = EnrichedPhoto(id: "L-y", captureDate: nil, latitude: nil, longitude: nil, placeName: nil)
        let line = AIAlbumSearcher.evidenceLine(index: 0, photo: photo, tags: [], caption: nil, faceCount: nil)
        #expect(line == "0)")
    }

    @Test("withIncludeTerms: include だけ差し替え・除外/ハードは維持・空なら節を立てる")
    func includeReplacement() {
        let spec = QuerySpec(clauses: [QueryClause([
            .content(["old"]),
            .not(.content(["people"])),
            .favorite,
        ])])
        let out = QuerySpecSanitizer.withIncludeTerms(spec, terms: ["scenery", "mountains"])
        #expect(out.clauses[0].conditions.contains(.content(["scenery", "mountains"])))
        #expect(!out.clauses[0].conditions.contains(.content(["old"])))
        #expect(out.clauses[0].conditions.contains(.not(.content(["people"]))))
        #expect(out.clauses[0].conditions.contains(.favorite))

        let empty = QuerySpecSanitizer.withIncludeTerms(QuerySpec(), terms: ["beach"])
        #expect(empty.clauses == [QueryClause([.content(["beach"])])])
    }
}
