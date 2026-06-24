import Foundation
import Testing
@testable import ImageCacheKit

/// `DiskImageStore` のディスク I/O・LRU 列挙プリミティブを検証する。
/// UIImage を介さない Foundation のみのコアなので macOS の `swift test` で実行できる。
@Suite("DiskImageStore")
struct DiskImageStoreTests {

    /// テストごとに独立した一時ディレクトリへ向けたストアを作る。
    private func makeStore() -> (DiskImageStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheKitTests-\(UUID().uuidString)", isDirectory: true)
        return (DiskImageStore(directory: dir), dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("write → data round trip")
    func writeReadRoundTrip() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        let payload = Data("hello".utf8)
        store.write(payload, name: "a.bin")
        #expect(store.data(forName: "a.bin") == payload)
    }

    @Test("missing file returns nil / size 0")
    func missingFile() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        #expect(store.data(forName: "nope.bin") == nil)
        #expect(store.fileSize(forName: "nope.bin") == 0)
    }

    @Test("fileSize と totalUsage が書き込みバイト数を反映する")
    func sizeAndUsage() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        store.write(Data(repeating: 0, count: 100), name: "a.bin")
        store.write(Data(repeating: 0, count: 250), name: "b.bin")
        #expect(store.fileSize(forName: "a.bin") == 100)
        #expect(store.totalUsage() == 350)
    }

    @Test("remove は単一ファイルを削除し使用量を減らす")
    func remove() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        store.write(Data(repeating: 0, count: 100), name: "a.bin")
        store.write(Data(repeating: 0, count: 100), name: "b.bin")
        store.remove(name: "a.bin")
        #expect(store.data(forName: "a.bin") == nil)
        #expect(store.totalUsage() == 100)
    }

    @Test("clear は全ファイルを削除する")
    func clear() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        store.write(Data(repeating: 0, count: 10), name: "a.bin")
        store.write(Data(repeating: 0, count: 10), name: "b.bin")
        store.clear()
        #expect(store.totalUsage() == 0)
        #expect(store.entries().isEmpty)
    }

    @Test("entries はサイズと更新日時を返す")
    func entriesMetadata() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        store.write(Data(repeating: 0, count: 42), name: "a.bin")
        let entries = store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.size == 42)
    }

    @Test("touch は mtime を更新し LRU 並び（古い順）を変える")
    func touchAffectsLRUOrdering() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        // a を古い時刻、b を新しい時刻に設定 → 古い順は [a, b]
        store.write(Data(repeating: 0, count: 10), name: "a.bin")
        store.write(Data(repeating: 0, count: 10), name: "b.bin")
        let base = Date(timeIntervalSince1970: 1_000_000)
        store.touch(name: "a.bin", date: base)
        store.touch(name: "b.bin", date: base.addingTimeInterval(60))

        let oldestFirst = store.entries().sorted { $0.modified < $1.modified }
        #expect(oldestFirst.map { $0.url.lastPathComponent } == ["a.bin", "b.bin"])

        // a を最新に touch → 古い順は [b, a] に入れ替わる（mtime LRU の前提）
        store.touch(name: "a.bin", date: base.addingTimeInterval(120))
        let reordered = store.entries().sorted { $0.modified < $1.modified }
        #expect(reordered.map { $0.url.lastPathComponent } == ["b.bin", "a.bin"])
    }

    @Test("LRU 破棄シミュレーション: 上限超過分を古い順に削除して縮む")
    func lruEvictionSimulation() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        let base = Date(timeIntervalSince1970: 2_000_000)
        // 100B × 5 = 500B。上限 250B の 80%(=200B) まで古い順に削除する想定。
        for i in 0..<5 {
            let name = "f\(i).bin"
            store.write(Data(repeating: 0, count: 100), name: name)
            store.touch(name: name, date: base.addingTimeInterval(TimeInterval(i)))
        }
        #expect(store.totalUsage() == 500)

        // 利用側 LRU ポリシーを模した削除ループ
        let limit = 250
        let target = limit * 4 / 5  // 200
        var usage = store.totalUsage()
        for entry in store.entries().sorted(by: { $0.modified < $1.modified }) {
            guard usage > target else { break }
            store.removeFile(at: entry.url)
            usage -= entry.size
        }
        #expect(store.totalUsage() <= target)
        // 最古の f0,f1,f2 が消え、新しい f3,f4 が残る
        let remaining = Set(store.entries().map { $0.url.lastPathComponent })
        #expect(remaining == ["f3.bin", "f4.bin"])
    }
}
