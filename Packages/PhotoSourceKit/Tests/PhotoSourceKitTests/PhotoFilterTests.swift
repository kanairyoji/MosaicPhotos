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
}
