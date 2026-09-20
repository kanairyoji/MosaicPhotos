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

    /// **エンコードがどのスレッドで走ったか**を自分で記録する値。
    /// ⚠️ 「保存できた」だけを見るテストは、呼び出し元のスレッドで書く実装に戻しても通る
    /// （＝直したはずの停止を検出できない）。観測したいのは*どこで走ったか*なので、
    /// `encode(to:)` の中で記録する。
    private struct ThreadProbe: Codable, Sendable, Equatable {
        final class Sink: @unchecked Sendable { var encodedOnMain: Bool? }
        static let sink = Sink()
        let name: String

        init(name: String) { self.name = name }

        func encode(to encoder: any Encoder) throws {
            Self.sink.encodedOnMain = Thread.isMainThread
            var container = encoder.singleValueContainer()
            try container.encode(name)
        }

        init(from decoder: any Decoder) throws {
            name = try decoder.singleValueContainer().decode(String.self)
        }
    }

    /// ⚠️ 大きいキャッシュ（数万件）を MainActor から `save` すると、エンコードと書き込みが
    /// そのまま前面の停止になる（CLAUDE.md 性能原則 4）。`saveInBackground` は呼び出し元の
    /// スレッドから外して書く——**呼び出し元がメインでも、エンコードはメインで走らないこと**。
    @Test("saveInBackground は呼び出し元のスレッドでエンコードしない")
    @MainActor
    func saveInBackgroundLeavesTheCallersThread() async {
        defer { cleanup() }
        let store = JSONFileStore<ThreadProbe>(filename: uniqueName())
        ThreadProbe.sink.encodedOnMain = nil
        #expect(Thread.isMainThread, "前提: 呼び出し元はメインスレッド")

        await store.saveInBackground(ThreadProbe(name: "Kyoto")).value

        #expect(ThreadProbe.sink.encodedOnMain == false,
                "呼び出し元（メイン）でエンコードしている＝前面が止まる")
        #expect(store.load() == ThreadProbe(name: "Kyoto"), "背景で保存したのに読み戻せない")
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
