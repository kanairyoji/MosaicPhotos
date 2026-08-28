import Foundation
import Testing
@testable import PhotoSourceKit

/// サムネイルビュー共通フィルタ（PhotoFilter）の純ロジック。
@Suite("PhotoFilter")
struct PhotoFilterTests {
    private struct StubItem: PhotoItem {
        let id: String
        var captureDate: Date? { nil }
        var isFavorite: Bool
        var isCloudSource: Bool = false
    }

    @Test("既定（未フィルタ）は素通し・isActive=false")
    func inactivePassesThrough() {
        let items = [StubItem(id: "a", isFavorite: false), StubItem(id: "b", isFavorite: true)]
        let filter = PhotoFilter()
        #expect(!filter.isActive)
        #expect(filter.apply(items).map(\.id) == ["a", "b"])
    }

    @Test("お気に入りのみ: isFavorite だけ残る（順序維持）")
    func favoritesOnlyFilters() {
        let items = [StubItem(id: "a", isFavorite: false),
                     StubItem(id: "b", isFavorite: true),
                     StubItem(id: "c", isFavorite: false),
                     StubItem(id: "d", isFavorite: true)]
        var filter = PhotoFilter()
        filter.favoritesOnly = true
        #expect(filter.isActive)
        #expect(filter.apply(items).map(\.id) == ["b", "d"])
    }

    @Test("ソース絞り込み: 端末のみ／クラウドのみ")
    func sourceFilters() {
        let items = [StubItem(id: "local1", isFavorite: false),
                     StubItem(id: "cloud1", isFavorite: false, isCloudSource: true),
                     StubItem(id: "local2", isFavorite: true),
                     StubItem(id: "cloud2", isFavorite: true, isCloudSource: true)]
        var filter = PhotoFilter()
        filter.source = .localOnly
        #expect(filter.isActive)
        #expect(filter.apply(items).map(\.id) == ["local1", "local2"])
        filter.source = .cloudOnly
        #expect(filter.apply(items).map(\.id) == ["cloud1", "cloud2"])
    }

    @Test("ベストショットのみ: 判定クロージャで残す（順序維持）")
    func beautifulOnlyFilters() {
        let items = [StubItem(id: "a", isFavorite: false),
                     StubItem(id: "b", isFavorite: false),
                     StubItem(id: "c", isFavorite: true)]
        var filter = PhotoFilter()
        filter.beautifulOnly = true
        #expect(filter.isActive)
        let beautiful: Set<String> = ["a", "c"]
        #expect(filter.apply(items, isBeautiful: { beautiful.contains($0.id) }).map(\.id) == ["a", "c"])
    }

    @Test("ベストショット: 判定未提供（読み込み中）は素通し")
    func beautifulWithoutMembershipPassesThrough() {
        let items = [StubItem(id: "a", isFavorite: false), StubItem(id: "b", isFavorite: true)]
        var filter = PhotoFilter()
        filter.beautifulOnly = true
        #expect(filter.apply(items).map(\.id) == ["a", "b"])
    }

    @Test("複合: ベストショット×お気に入りは AND で効く")
    func combinedBeautifulAndFavorite() {
        let items = [StubItem(id: "goodFav", isFavorite: true),
                     StubItem(id: "good", isFavorite: false),
                     StubItem(id: "fav", isFavorite: true)]
        var filter = PhotoFilter()
        filter.beautifulOnly = true
        filter.favoritesOnly = true
        let beautiful: Set<String> = ["goodFav", "good"]
        #expect(filter.apply(items, isBeautiful: { beautiful.contains($0.id) }).map(\.id) == ["goodFav"])
    }

    @Test("複合: お気に入り×ソースは AND で効く")
    func combinedFavoriteAndSource() {
        let items = [StubItem(id: "local1", isFavorite: false),
                     StubItem(id: "localFav", isFavorite: true),
                     StubItem(id: "cloudFav", isFavorite: true, isCloudSource: true)]
        var filter = PhotoFilter()
        filter.favoritesOnly = true
        filter.source = .localOnly
        #expect(filter.apply(items).map(\.id) == ["localFav"])
    }
}

// MARK: - 実体の所在（PhotoSourceLocation）

/// ⚠️ 「見覚えのない写真が一覧に出る」類の不具合は、**その写真がどこの実体か**が分からないと
/// 切り分けられない（実測: 実機ログからは由来フォルダを特定できなかった）。
/// フル画面に出す所在は、合成 id ではなく実体のパス／識別子であること。
@Suite("写真の所在")
struct PhotoSourceLocationTests {

    @Test("クラウドはフルパスをそのまま持つ")
    func cloudKeepsFullPath() {
        let location = PhotoSourceLocation(kind: .cloud, identifier: "/MosaicPhotos/IMG_0001.JPG")
        #expect(location.kind == .cloud)
        #expect(location.identifier == "/MosaicPhotos/IMG_0001.JPG",
                "切り詰めると肝心の場所が読めない")
    }

    @Test("端末は localIdentifier をそのまま持つ")
    func localKeepsIdentifier() {
        #expect(PhotoSourceLocation(kind: .local, identifier: "ABC-123/L0/001").identifier
                == "ABC-123/L0/001")
    }

    /// パスを持たないソース向けの既定実装。
    private struct PlainItem: PhotoItem {
        let id: String
        var captureDate: Date? { nil }
        var isCloudSource: Bool
    }

    @Test("既定の実装はソース種別を引き継ぎ、id を所在として出す")
    func defaultUsesCloudFlag() {
        let cloud = PlainItem(id: "c", isCloudSource: true).sourceLocation
        #expect(cloud.kind == .cloud)
        #expect(cloud.identifier == "c")
        #expect(PlainItem(id: "l", isCloudSource: false).sourceLocation.kind == .local)
    }
}
