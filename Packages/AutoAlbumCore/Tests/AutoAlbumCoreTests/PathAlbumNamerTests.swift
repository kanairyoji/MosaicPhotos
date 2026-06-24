import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("PathAlbumNamer (path → album name)")
struct PathAlbumNamerTests {

    @Test("名前付きキャプチャでフォルダ名を取り出す")
    func namedCapture() {
        let rules = [PathAlbumRule(pattern: "^/Trips/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/Trips/Hawaii/IMG_0001.jpg", rules: rules) == "Hawaii")
    }

    @Test("番号キャプチャと日付プレフィックス除去")
    func numberedCaptureStripsDate() {
        let rules = [PathAlbumRule(pattern: "^/Photos/\\d{4}-\\d{2} ([^/]+)/[^/]+$", template: "$1")]
        #expect(PathAlbumNamer.name(forPath: "/Photos/2019-08 Kyoto/a.jpg", rules: rules) == "Kyoto")
    }

    @Test("複数グループをテンプレートで合成する")
    func templateComposition() {
        let rules = [PathAlbumRule(pattern: "^/Albums/(?<year>\\d{4})/(?<name>[^/]+)/", template: "${name} ${year}")]
        #expect(PathAlbumNamer.name(forPath: "/Albums/2021/Kyoto/x.jpg", rules: rules) == "Kyoto 2021")
    }

    @Test("無マッチは nil（意味のないパスを除外）")
    func noMatchReturnsNil() {
        let rules = [PathAlbumRule(pattern: "^/Trips/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/Camera Uploads/2019-05-01 12.00.00.jpg", rules: rules) == nil)
    }

    @Test("最初にマッチしたルールが優先される")
    func firstMatchWins() {
        let rules = [
            PathAlbumRule(pattern: "^/Trips/(?<name>[^/]+)/", template: "${name}"),
            PathAlbumRule(pattern: "^/(?<name>[^/]+)/", template: "${name}"),
        ]
        let result = PathAlbumNamer.preview(path: "/Trips/Bali/p.jpg", rules: rules)
        #expect(result?.index == 0)
        #expect(result?.name == "Bali")
    }

    @Test("アンダースコア/ハイフンは空白へ正規化する")
    func normalizesSeparators() {
        let rules = [PathAlbumRule(pattern: "^/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/Summer_Trip-2020/p.jpg", rules: rules) == "Summer Trip 2020")
    }

    @Test("大文字小文字を無視できる")
    func caseInsensitive() {
        let rules = [PathAlbumRule(pattern: "^/trips/(?<name>[^/]+)/", template: "${name}", caseInsensitive: true)]
        #expect(PathAlbumNamer.name(forPath: "/TRIPS/Rome/p.jpg", rules: rules) == "Rome")
    }

    @Test("不正な正規表現は無視される（クラッシュしない）")
    func invalidPatternIgnored() {
        let rules = [PathAlbumRule(pattern: "^/Trips/(unclosed", template: "$1")]
        #expect(PathAlbumNamer.name(forPath: "/Trips/X/p.jpg", rules: rules) == nil)
        #expect(PathAlbumNamer.isValidPattern("^/Trips/(unclosed") == false)
        #expect(PathAlbumNamer.isValidPattern("^/Trips/(?<name>[^/]+)/") == true)
    }

    @Test("空白のみの抽出は破棄する")
    func dropsWhitespaceOnly() {
        let rules = [PathAlbumRule(pattern: "^/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/   /p.jpg", rules: rules) == nil)
    }

    @Test("日本語のパス・フォルダ名を抽出できる")
    func japanesePath() {
        let rules = [PathAlbumRule(pattern: "^/写真/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/写真/京都旅行/IMG_0001.jpg", rules: rules) == "京都旅行")
    }

    @Test("テンプレートに日本語リテラルを混在できる")
    func japaneseTemplate() {
        let rules = [PathAlbumRule(pattern: "^/(?<place>[^/]+)/(?<year>\\d{4})/", template: "${place} ${year}年")]
        #expect(PathAlbumNamer.name(forPath: "/沖縄/2021/a.jpg", rules: rules) == "沖縄 2021年")
    }

    @Test("1文字の漢字フォルダ名も保持する（任意 UTF-8 を許可）")
    func keepsSingleCJK() {
        let rules = [PathAlbumRule(pattern: "^/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/京/p.jpg", rules: rules) == "京")
    }

    @Test("絵文字など BMP 外の文字も壊れない")
    func handlesNonBMP() {
        let rules = [PathAlbumRule(pattern: "^/(?<name>[^/]+)/", template: "${name}")]
        #expect(PathAlbumNamer.name(forPath: "/🏖️Beach/p.jpg", rules: rules) == "🏖️Beach")
    }
}
