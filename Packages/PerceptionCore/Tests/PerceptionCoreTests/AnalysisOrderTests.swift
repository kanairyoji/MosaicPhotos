import Testing
@testable import PerceptionCore

@Suite("AnalysisOrder (お気に入り優先の処理順)")
struct AnalysisOrderTests {
    @Test("お気に入り(ローカル→クラウド)→その他(ローカル→クラウド)・群内は元順(新→古)維持")
    func favoritesFirst() {
        // 入力は各群内で新→古（撮影日降順の列挙を模す）。ローカル/クラウド混在。
        let input = ["L-a", "C-b", "L-c", "C-d", "L-e", "C-f"]
        let favorites: Set<String> = ["L-c", "C-d"]   // お気に入り: ローカル L-c ・ クラウド C-d
        let out = AnalysisOrder.ordered(input, favorites: favorites)
        // favLocal[L-c] → favCloud[C-d] → nonfavLocal[L-a,L-e] → nonfavCloud[C-b,C-f]
        #expect(out == ["L-c", "C-d", "L-a", "L-e", "C-b", "C-f"])
    }

    @Test("お気に入り無し: ローカル→クラウド（各群内は元順維持）")
    func noFavorites() {
        let input = ["C-b", "L-a", "C-d", "L-c"]
        #expect(AnalysisOrder.ordered(input, favorites: []) == ["L-a", "L-c", "C-b", "C-d"])
    }

    @Test("群インデックス: fav×local=0 / fav×cloud=1 / other×local=2 / other×cloud=3")
    func groupIndex() {
        let fav: Set<String> = ["L-x", "C-y"]
        #expect(AnalysisOrder.groupIndex("L-x", favorites: fav) == 0)
        #expect(AnalysisOrder.groupIndex("C-y", favorites: fav) == 1)
        #expect(AnalysisOrder.groupIndex("L-z", favorites: fav) == 2)
        #expect(AnalysisOrder.groupIndex("C-z", favorites: fav) == 3)
    }
}
