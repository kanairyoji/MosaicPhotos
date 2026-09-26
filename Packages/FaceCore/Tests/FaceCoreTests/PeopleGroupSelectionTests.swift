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

    // MARK: - 編集画面に出す人

    /// ⚠️ メンバーの写真が減って表示フロアを割ると、一覧から消えて**外せなくなる**
    /// ——見えない・触れないメンバーがグループに居座る。
    @Test("表示フロアで隠れた人でも、既にメンバーなら一覧に出す")
    func selectableKeepsHiddenMembers() {
        let shownPerson = person(10)
        let hiddenMember = person(7)
        let hiddenStranger = person(99)
        let list = PeopleGroupSelection.selectable(
            shown: [shownPerson], all: [shownPerson, hiddenMember, hiddenStranger],
            initialMembers: [10, 7])
        #expect(list.map(\.clusterID) == [10, 7], "隠れたメンバーが出ていない: \(list.map(\.clusterID))")
    }

    @Test("メンバーでない人はフロアどおり隠したまま（1,300 人を並べない）")
    func selectableDoesNotShowNonMembers() {
        let shownPerson = person(10)
        let hiddenStranger = person(99)
        let list = PeopleGroupSelection.selectable(
            shown: [shownPerson], all: [shownPerson, hiddenStranger], initialMembers: [10])
        #expect(list.map(\.clusterID) == [10])
    }

    @Test("同じ人を 2 回並べない（表示側にも居るメンバー）")
    func selectableDoesNotDuplicate() {
        let shownPerson = person(10, bundled: [10, 42])
        let list = PeopleGroupSelection.selectable(
            shown: [shownPerson], all: [shownPerson], initialMembers: [42])
        #expect(list.count == 1)
    }

    /// ⚠️ 基準を**いまのチェック状態**にすると、隠れていたメンバーを外した瞬間に行が消えて
    /// 戻せなくなる（名前も打ち直していたら「やめる」で全部捨てるしかない）。
    @Test("隠れていたメンバーを外しても、一覧から消えない（戻せる）")
    func selectableKeepsHiddenMemberAfterUnchecking() {
        let shownPerson = person(10)
        let hiddenMember = person(7)
        // 開いた時点のメンバーは {10, 7}。7 を外した状態でも一覧には残る。
        let list = PeopleGroupSelection.selectable(
            shown: [shownPerson], all: [shownPerson, hiddenMember], initialMembers: [10, 7])
        #expect(list.map(\.clusterID) == [10, 7])
    }

    // MARK: - メンバー数（保存の可否）

    /// ⚠️ 解決できない記録上の ID を数えないと、ライブラリが変わった瞬間に
    /// **保存ボタンが永久に灰色**になり、名前も変えられずメンバーも外せなくなる。
    @Test("解決できない記録上の ID も 1 人として数える")
    func memberCountCountsUnresolvedRecords() {
        let alive = person(10)
        // 999 はもう誰にも解決しない記録上のメンバー。
        #expect(PeopleGroupSelection.memberCount(in: [10, 999], among: [alive]) == 2)
        #expect(PeopleGroupSelection.personCount(in: [10, 999], among: [alive]) == 1,
                "personCount は解決できたものだけ（役割の違いを固定する）")
    }

    @Test("束ねの 2 つの ID は、解決できる 1 人として数える（2 人に見せない）")
    func memberCountDoesNotDoubleCountABundledPerson() {
        let grouped = person(10, bundled: [10, 42])
        #expect(PeopleGroupSelection.memberCount(in: [10, 42], among: [grouped]) == 1)
    }

    /// ⚠️ 「2 人以上」は**メンバーを変えるとき**の決まり。名前だけ直すのを止めると、
    /// 再スキャンの最中（`reset()` がメンバーを空にする・世代切り替えが空の器を作る）に
    /// **数晩ずっと改名できない**——「保存ボタンが永久に灰色」を別の入口から作ってしまう。
    @Test("名前だけ直すときは人数を問わない（メンバーを変えるときだけ 2 人以上）")
    func allowsRenameRegardlessOfMemberCount() {
        #expect(PeopleGroupSelection.allowsSave(memberCount: 0, isRenameOnly: true))
        #expect(PeopleGroupSelection.allowsSave(memberCount: 1, isRenameOnly: true))
        #expect(!PeopleGroupSelection.allowsSave(memberCount: 1, isRenameOnly: false))
        #expect(!PeopleGroupSelection.allowsSave(memberCount: 0, isRenameOnly: false))
        #expect(PeopleGroupSelection.allowsSave(memberCount: 2, isRenameOnly: false))
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
