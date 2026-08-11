import Foundation
import Testing
@testable import AutoAlbumCore

/// 活動・イベント語の一括拡充（ADR-110・実フィードバック「バレエ」）。
/// 英語側は Vision 1,303 クラスの実在識別子を優先（tagHits の多語一致でタグに当たる）。
@Suite("LexiconActivityWords (活動・イベント語)")
struct LexiconActivityWordsTests {

    @Test("バレエ・サッカー・発表会などが英語タグ語へ落ちる")
    func activityWordsGround() {
        #expect(JapaneseVisualLexicon.includeTerms(in: "バレエの写真") == ["ballet", "ballet dancer"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "サッカーの試合") == ["soccer"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "発表会の写真").contains("performance"))
        #expect(JapaneseVisualLexicon.includeTerms(in: "運動会") .contains("athletics"))
        #expect(JapaneseVisualLexicon.includeTerms(in: "水族館に行った日") == ["aquarium"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "クリスマスの写真").contains("christmas tree"))
    }

    @Test("多語識別子は tagHits でアンダースコア入りタグに当たる")
    func multiWordTermsMatchUnderscoredTags() {
        // Vision の識別子はアンダースコア形（ballet_dancer）。レキシコンは空白形で持ち、
        // tagHits のトークン一致（多語 term＝全トークン同一タグ内）で当たることを固定する。
        #expect(AIAlbumSearcher.tagHits(["ballet_dancer"], terms: ["ballet dancer"]) == 1)
        #expect(AIAlbumSearcher.tagHits(["christmas_tree"], terms: ["christmas tree"]) == 1)
        #expect(AIAlbumSearcher.tagHits(["ballet"], terms: ["ballet"]) == 1)
        // 単一語 term はタグ全体一致のみ（S5: "dog" が "hot dog" に当たらない規則の維持）。
        #expect(AIAlbumSearcher.tagHits(["ballet_dancer"], terms: ["dancer"]) == 0)
    }

    @Test("最長一致の占有: パンダはパンに化けない・スケートボードはスケートに化けない")
    func longestMatchOccupancy() {
        #expect(JapaneseVisualLexicon.includeTerms(in: "パンダの写真") == ["panda"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "スケートボードの写真") == ["skateboard"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "パンケーキの朝食") == ["pancake"])
    }

    @Test("単漢字（庭・森・城）は漢字隣接で一致させない")
    func singleKanjiAdjacencyGuard() {
        // 「家庭」の 庭・「青森」の 森・「宮城」の 城 は複合語＝視覚語として拾わない。
        #expect(!JapaneseVisualLexicon.includeTerms(in: "家庭の写真").contains("garden"))
        #expect(!JapaneseVisualLexicon.includeTerms(in: "青森の旅行").contains("forest"))
        #expect(!JapaneseVisualLexicon.includeTerms(in: "宮城の写真").contains("castle"))
        // 単独・かな隣接なら拾う。
        #expect(JapaneseVisualLexicon.includeTerms(in: "お庭の写真") == ["garden"])
        #expect(JapaneseVisualLexicon.includeTerms(in: "森の写真") == ["forest"])
    }
}
