import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("PersonNameGrounder (人物名の接地)")
struct PersonNameGrounderTests {
    let catalog = ["木村太郎", "木村花子", "田中一郎"]

    @Test("名だけで姓名フルネームに当たる（太郎→木村太郎）")
    func givenNameMatchesFullName() {
        let r = PersonNameGrounder.groundedNames(in: "太郎の写真", names: catalog)
        #expect(r == ["木村太郎"])
    }

    @Test("複数人物（太郎と花子）を両方拾う")
    func multiplePeople() {
        let r = PersonNameGrounder.groundedNames(in: "太郎と花子", names: catalog)
        #expect(r.contains("木村太郎"))
        #expect(r.contains("木村花子"))
        #expect(!r.contains("田中一郎"))
    }

    @Test("姓（前方）で同姓の全員に当たる（木村→木村太郎・木村花子）")
    func familyNameMatchesAll() {
        let r = PersonNameGrounder.groundedNames(in: "木村さんの家族", names: catalog)
        #expect(r.contains("木村太郎"))
        #expect(r.contains("木村花子"))
        #expect(!r.contains("田中一郎"))
    }

    @Test("フルネームそのものにも当たる")
    func fullNameMatches() {
        let r = PersonNameGrounder.groundedNames(in: "田中一郎", names: catalog)
        #expect(r == ["田中一郎"])
    }

    @Test("無関係なクエリでは当たらない")
    func noFalsePositive() {
        #expect(PersonNameGrounder.groundedNames(in: "海の風景", names: catalog).isEmpty)
        #expect(PersonNameGrounder.groundedNames(in: "", names: catalog).isEmpty)
    }

    @Test("中間だけの部分文字列では当てない（村太で木村太郎に当てない）")
    func noMiddleSubstringMatch() {
        // "村太" は木村太郎の中間片。姓（前方）でも名（後方）でもないので当てない。
        #expect(PersonNameGrounder.groundedNames(in: "村太", names: ["木村太郎"]).isEmpty)
    }

    @Test("カタログが空なら空")
    func emptyCatalog() {
        #expect(PersonNameGrounder.groundedNames(in: "太郎", names: []).isEmpty)
    }

    @Test("ローマ字（スペース区切り）でも名で当たる")
    func romajiGivenName() {
        let r = PersonNameGrounder.groundedNames(in: "photos of taro", names: ["Kimura Taro"])
        #expect(r == ["Kimura Taro"])
    }

    @Test("nameParts は全体＋前方＋後方のみ（中間なし）")
    func namePartsShape() {
        let parts = Set(PersonNameGrounder.nameParts("木村太郎"))
        #expect(parts.contains("木村太郎"))   // 全体
        #expect(parts.contains("木村"))       // 前方2
        #expect(parts.contains("太郎"))       // 後方2
        #expect(parts.contains("木村太"))     // 前方3
        #expect(parts.contains("村太郎"))     // 後方3
        #expect(!parts.contains("村太"))      // 中間2 は含めない
    }
}
