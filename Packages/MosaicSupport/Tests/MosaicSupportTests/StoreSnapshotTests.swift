import Foundation
import Testing
@testable import MosaicSupport

/// 台帳の「開く前の控え」（ADR-186）。
@Suite("StoreSnapshot")
struct StoreSnapshotTests {

    private func tempStore() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("Ledger.store")
        try Data("v1".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        return store
    }

    @Test("版が変わった最初の 1 回だけ控えを取り、同じ版では取り直さない")
    func takesOncePerBuild() throws {
        let defaults = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
        let store = try tempStore()
        let name = "T-\(UUID().uuidString)"
        #expect(StoreSnapshot.takeIfBuildChanged(name: name, storeURL: store, defaults: defaults, marker: "1.0(1)"))
        #expect(!StoreSnapshot.takeIfBuildChanged(name: name, storeURL: store, defaults: defaults, marker: "1.0(1)"),
                "同じ版で取り直している")
        #expect(StoreSnapshot.takeIfBuildChanged(name: name, storeURL: store, defaults: defaults, marker: "1.1(2)"),
                "版が変わったのに取らない")
        try? FileManager.default.removeItem(at: StoreSnapshot.directory(for: name))
    }

    @Test("控えから戻せる（本体・wal）")
    func restores() throws {
        let defaults = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
        let store = try tempStore()
        let name = "T-\(UUID().uuidString)"
        #expect(StoreSnapshot.takeIfBuildChanged(name: name, storeURL: store, defaults: defaults, marker: "1.0(1)"))
        // 壊れた＝中身が変わった。
        try Data("corrupt".utf8).write(to: store)
        #expect(StoreSnapshot.restore(name: name, storeURL: store))
        #expect(String(data: try Data(contentsOf: store), encoding: .utf8) == "v1")
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal"))
        try? FileManager.default.removeItem(at: StoreSnapshot.directory(for: name))
    }

    @Test("控えが無ければ戻さない")
    func noSnapshotNoRestore() throws {
        let store = try tempStore()
        #expect(!StoreSnapshot.restore(name: "none-\(UUID().uuidString)", storeURL: store))
    }
}
