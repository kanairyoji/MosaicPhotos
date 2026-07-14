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

    @Test("フルネーム入力は同姓の家族へ波及しない（木村太郎→木村花子に当てない）")
    func fullNameDoesNotSpillToFamily() {
        // 実障害: 「木村太郎」の姓片「木村」が部分照合で木村花子にも当たり家族全員がヒットした。
        // 完全一致した名前はそれ以上分解せず、一致箇所を消費してから残りを部分照合する。
        let r = PersonNameGrounder.groundedNames(in: "木村太郎の写真", names: catalog)
        #expect(r == ["木村太郎"])
    }

    @Test("フルネーム＋名の複合（木村太郎と花子）は両方に当たる")
    func fullNamePlusGivenName() {
        let r = PersonNameGrounder.groundedNames(in: "木村太郎と花子", names: catalog)
        #expect(r.contains("木村太郎"))
        #expect(r.contains("木村花子"))
        #expect(!r.contains("田中一郎"))
    }

    @Test("完全一致は長い名前を優先（木村太と木村太郎が両方いる場合）")
    func longestFullNameWins() {
        let r = PersonNameGrounder.groundedNames(in: "木村太郎", names: ["木村太", "木村太郎"])
        #expect(r == ["木村太郎"])
    }

    @Test("1文字の名は部分照合しない（現仕様＝誤爆防止。フルネームなら当たる）")
    func singleCharGivenNameLimitation() {
        // 「健」だけでは当てない（「健康」「健やか」等の通常語に誤爆するため）。
        // フルネーム（またはサジェストチップからの挿入＝フルネーム）なら当たる。
        #expect(PersonNameGrounder.groundedNames(in: "健の写真", names: ["木村健"]).isEmpty)
        #expect(PersonNameGrounder.groundedNames(in: "木村健の写真", names: ["木村健"]) == ["木村健"])
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
