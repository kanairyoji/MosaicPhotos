import Foundation
import Testing
@testable import PhotoSourceKit

// 各テストが共有ディレクトリ（JSONFileStoreTests/）を defer で削除するため、
// 並列実行だと相互に消し合う。直列実行で隔離する。
@Suite("JSONFileStore", .serialized)
struct JSONFileStoreTests {

    private struct Sample: Codable, Equatable {
        let name: String
        let count: Int
    }

    /// テストごとにユニークなファイル名（後始末まで含めて衝突しないように）。
    private func uniqueName() -> String { "JSONFileStoreTests/\(UUID().uuidString).json" }

    private func cleanup() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("JSONFileStoreTests"))
    }

    @Test("save した値を load で復元できる")
    func roundTrip() {
        defer { cleanup() }
        let store = JSONFileStore<Sample>(filename: uniqueName())
        let value = Sample(name: "Tokyo", count: 3)
        store.save(value)
        #expect(store.load() == value)
    }

    @Test("未存在ファイルの load は nil")
    func missingFileReturnsNil() {
        defer { cleanup() }
        let store = JSONFileStore<Sample>(filename: uniqueName())
        #expect(store.load() == nil)
    }

    @Test("壊れた JSON の load は nil（クラッシュしない）")
    func corruptDataReturnsNil() throws {
        defer { cleanup() }
        let name = uniqueName()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = JSONFileStore<Sample>(filename: name)
        #expect(store.load() == nil)
    }

    @Test("ネストしたディレクトリを自動生成して書き込む")
    func createsNestedDirectories() {
        defer { cleanup() }
        let store = JSONFileStore<Sample>(filename: "JSONFileStoreTests/a/b/c/\(UUID().uuidString).json")
        store.save(Sample(name: "x", count: 1))
        #expect(store.load() == Sample(name: "x", count: 1))
    }

    @Test("save は既存ファイルを上書きする")
    func overwrites() {
        defer { cleanup() }
        let store = JSONFileStore<Sample>(filename: uniqueName())
        store.save(Sample(name: "old", count: 1))
        store.save(Sample(name: "new", count: 2))
        #expect(store.load() == Sample(name: "new", count: 2))
    }

    @Test("配列値も保存・復元できる")
    func arrayValue() {
        defer { cleanup() }
        let store = JSONFileStore<[Sample]>(filename: uniqueName())
        let values = [Sample(name: "a", count: 1), Sample(name: "b", count: 2)]
        store.save(values)
        #expect(store.load() == values)
    }
}
