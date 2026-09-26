import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// グループ編集シートの「選ばれているか」（ADR-232）。
///
/// ⚠️ グループの記録は人物を **clusterID（代表クラスタ）** で指しているが、代表は束ねの中で
/// 入れ替わる（別のクラスタに名前が付く・枚数が変わる・再スキャンで並びが変わる）。
/// 表示側（`PeopleGroupInfo.resolve`）は構成クラスタのどれでも引けるようにしたので、
/// **編集シートが代表 ID だけを見ていると食い違う**——アルバムには出ているのに編集画面では
/// チェックが付いておらず、「直そう」として押すと同じ人物が 2 回記録に入る。
@Suite("グループ編集シートの選択判定")
struct PeopleGroupSelectionTests {

    private func person(_ clusterID: Int, bundled: [Int] = []) -> PersonInfo {
        var p = PersonInfo(clusterID: clusterID, name: nil, count: 1,
                           coverRefKey: nil, coverBoundingBox: nil, memberRefKeys: [])
        p.clusterIDs = bundled.isEmpty ? [clusterID] : bundled
        p.isGrouped = bundled.count > 1
        return p
    }

    @Test("代表 ID で指されていれば選択済み")
    func selectedByRepresentative() {
        #expect(PeopleGroupSelection.isSelected(person(10), in: [10]))
        #expect(!PeopleGroupSelection.isSelected(person(10), in: [11]))
    }

    /// これが直した本体。記録が **42**（束ねの非代表）を指していても、代表 10 の人物として
    /// チェックが付かなければならない。
    @Test("記録が束ねの非代表を指していても選択済みと分かる")
    func selectedByAnyBundledCluster() {
        let grouped = person(10, bundled: [10, 42])
        #expect(PeopleGroupSelection.isSelected(grouped, in: [42]))
        #expect(PeopleGroupSelection.isSelected(grouped, in: [10]))
        #expect(!PeopleGroupSelection.isSelected(grouped, in: [7]))
    }

    /// 外すときは**その人物の全 ID** を落とす。代表だけ落とすと、記録に残った非代表 ID で
    /// ふたたび「選択済み」に見え、外せなくなる。
    @Test("外すと、その人物を指す ID が記録から全部消える")
    func removingDropsEveryIDOfThatPerson() {
        let grouped = person(10, bundled: [10, 42])
        var selected: Set<Int> = [10, 42, 99]
        selected.subtract(PeopleGroupSelection.ids(of: grouped))
        #expect(selected == [99])
        #expect(!PeopleGroupSelection.isSelected(grouped, in: selected))
    }

    /// 「2 人以上」を **ID の数**で見ると、1 人を 2 通りで指しただけで作成できてしまう。
    @Test("人数は人物単位で数える（同じ人物の 2 つの ID を 2 人と数えない）")
    func personCountCountsPeopleNotIDs() {
        let grouped = person(10, bundled: [10, 42])
        let other = person(7)
        #expect(PeopleGroupSelection.personCount(in: [10, 42], among: [grouped, other]) == 1)
        #expect(PeopleGroupSelection.personCount(in: [10, 42, 7], among: [grouped, other]) == 2)
        #expect(PeopleGroupSelection.personCount(in: [], among: [grouped, other]) == 0)
    }

    /// 一覧に居ない ID（消えた人物）は数えない——記録に残骸があっても「2 人」に見せない。
    @Test("一覧に居ない ID は人数に数えない")
    func staleIDsDoNotCount() {
        #expect(PeopleGroupSelection.personCount(in: [10, 999], among: [person(10)]) == 1)
    }

    /// ⚠️ 母数は**表示フロアで隠した人も含む一覧**（`allPeople`）でなければならない。
    /// フロア未満のメンバーが入っているグループを編集したとき、母数が `people`（フロア済み）だと
    /// その人が数えられず、**2 人選んでいるのに保存できなくなる**。
    /// 呼び出し側の選択は UI にあるが、規則としてここで固定しておく。
    @Test("母数に居ない人物は数えられない（フロア済み一覧を渡すと数が足りなくなる）")
    func countDependsOnTheDenominator() {
        let shown = person(10)
        let hiddenByFloor = person(7)
        let selected: Set<Int> = [10, 7]
        #expect(PeopleGroupSelection.personCount(in: selected, among: [shown]) == 1,
                "フロア済みの母数では 1 人しか数えられない（＝保存できなくなる側）")
        #expect(PeopleGroupSelection.personCount(in: selected,
                                                among: [shown, hiddenByFloor]) == 2,
                "全件の母数なら 2 人と数えられる")
    }
}
