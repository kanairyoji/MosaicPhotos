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
