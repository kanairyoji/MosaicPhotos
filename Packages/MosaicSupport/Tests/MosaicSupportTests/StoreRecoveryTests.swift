import Foundation
import Testing
@testable import MosaicSupport

/// ⚠️ 永続ストアが開けない理由は色々ある。理由を見ずに削除すると、**ディスク容量不足や
/// ファイル保護（端末ロック中）のような一時的な失敗でも**、オフロード台帳・未送信マーカー・
/// 共有状態を失う。消えると二重アップロードや共有の齟齬になる（レビュー指摘）。
@Suite("StoreRecovery")
struct StoreRecoveryTests {

    private func cocoa(_ code: Int) -> NSError { NSError(domain: NSCocoaErrorDomain, code: code) }
    private func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    private func corrupt() -> NSError { NSError(domain: NSCocoaErrorDomain, code: 134100) }  // 移行不能
    private func sqlite(_ code: Int) -> NSError { NSError(domain: "NSSQLiteErrorDomain", code: code) }

    @Test("容量不足では何も消さない（台帳もキャッシュも）")
    func diskFullKeepsFiles() {
        for policy in [StoreRecoveryPolicy.ledger, .rebuildable] {
            #expect(StoreRecovery.action(for: cocoa(640), policy: policy) == .keepFilesUseMemory)
            #expect(StoreRecovery.action(for: posix(28), policy: policy) == .keepFilesUseMemory)
        }
    }

    @Test("ファイル保護（端末ロック中）でも何も消さない")
    func fileProtectionKeepsFiles() {
        #expect(StoreRecovery.action(for: cocoa(257), policy: .ledger) == .keepFilesUseMemory)
        #expect(StoreRecovery.action(for: posix(13), policy: .rebuildable) == .keepFilesUseMemory)
    }

    @Test("根本原因が一時的なら、包んだエラーでも一時的と判定する")
    func detectsTransientInUnderlyingError() {
        let wrapped = NSError(domain: "SwiftDataError", code: 1,
                              userInfo: [NSUnderlyingErrorKey: posix(28)])
        #expect(StoreRecovery.isTransient(wrapped))
    }

    /// ⚠️ SQLITE_BUSY/LOCKED は**ロック競合**であって破損ではない（別コンテナ・別プロセスが
    /// 一瞬掴んでいるだけ）。破損として扱うと台帳を退避して空で起動し、バックアップ済み判定を
    /// 失って二重アップロードになる（レビュー指摘）。
    @Test("SQLite のロック競合（BUSY/LOCKED）では何も消さない")
    func sqliteLockContentionKeepsFiles() {
        for policy in [StoreRecoveryPolicy.ledger, .rebuildable] {
            #expect(StoreRecovery.action(for: sqlite(5), policy: policy) == .keepFilesUseMemory,
                    "SQLITE_BUSY を破損として扱っている")
            #expect(StoreRecovery.action(for: sqlite(6), policy: policy) == .keepFilesUseMemory,
                    "SQLITE_LOCKED を破損として扱っている")
        }
    }

    @Test("ファイルロック（NSFileLockingError）も一時的な失敗")
    func fileLockingIsTransient() {
        #expect(StoreRecovery.action(for: cocoa(255), policy: .ledger) == .keepFilesUseMemory)
    }

    /// SQLite でも「壊れている」系のコードは破損として扱う（何でも一時的にはしない）。
    @Test("SQLITE_CORRUPT は破損として扱う")
    func sqliteCorruptIsNotTransient() {
        #expect(!StoreRecovery.isTransient(sqlite(11)))   // SQLITE_CORRUPT
        #expect(StoreRecovery.action(for: sqlite(11), policy: .ledger) == .quarantineAndRebuild)
    }

    @Test("破損・スキーマ不整合では、キャッシュは削除・台帳は退避")
    func corruptionDiffersByPolicy() {
        #expect(StoreRecovery.action(for: corrupt(), policy: .rebuildable) == .deleteAndRebuild)
        #expect(StoreRecovery.action(for: corrupt(), policy: .ledger) == .quarantineAndRebuild,
                "台帳を削除すると二重アップロード・共有の齟齬になる")
    }

    @Test("退避先は衝突しないよう連番になる")
    func quarantineNamesDoNotCollide() {
        let store = URL(fileURLWithPath: "/tmp/BackupKit.store")
        let first = StoreRecovery.quarantineURL(for: store) { _ in false }
        #expect(first.lastPathComponent == "BackupKit.store.corrupt")

        let taken: Set<String> = ["BackupKit.store.corrupt"]
        let second = StoreRecovery.quarantineURL(for: store) { taken.contains($0.lastPathComponent) }
        #expect(second.lastPathComponent == "BackupKit.store.corrupt2", "前回の退避を上書きしてしまう")
    }

    /// ⚠️ 既存の名前を返すと `moveItem` が失敗し、壊れたストアがその場に残る。
    /// すると次の起動でも開けず、**毎回インメモリに落ちる**状態が固定化する（レビュー指摘）。
    @Test("連番が埋まっていても、必ず存在しない名前を返す")
    func quarantineAlwaysReturnsFreeName() {
        let store = URL(fileURLWithPath: "/tmp/BackupKit.store")
        // .corrupt / .corrupt2 … .corrupt-last まで全部埋まっている状況を作る。
        var taken = Set(["BackupKit.store.corrupt", "BackupKit.store.corrupt-last"])
        for n in 2...200 { taken.insert("BackupKit.store.corrupt\(n)") }

        let url = StoreRecovery.quarantineURL(for: store) { taken.contains($0.lastPathComponent) }
        #expect(!taken.contains(url.lastPathComponent),
                "既存の名前を返している（退避に失敗して壊れたストアが残る）")
    }

    @Test("連番が全部埋まっていても空きを作る（上限の外側）")
    func quarantineFallsBackToUniqueName() {
        let store = URL(fileURLWithPath: "/tmp/BackupKit.store")
        // 連番は全て埋まっている（UUID 退避へ落ちる経路）。
        let url = StoreRecovery.quarantineURL(for: store) { candidate in
            candidate.lastPathComponent.hasPrefix("BackupKit.store.corrupt")
                && !candidate.lastPathComponent.contains("-")
        }
        #expect(url.lastPathComponent.hasPrefix("BackupKit.store.corrupt-"))
    }
}

/// ⚠️ 退避名は本体（`<store>.corrupt`）だけでなく `<store>-wal.corrupt` / `<store>-shm.corrupt`
/// も作られる。本体だけを見て「新しい順に N 件残す」と、WAL/SHM が対象から外れて溜まり続け、
/// しかも件数を**ファイル単位**で数えるため現役世代の WAL/SHM まで消えてしまう。
/// 刈り取りは**世代単位**で行う。
@Suite("退避ファイルの世代刈り")
struct QuarantinePruneTests {

    /// `<dir>/<base>` の退避を世代ぶん作る。世代ごとに本体・WAL・SHM の 3 ファイル。
    private func makeQuarantines(generations: [String], base: String, in dir: URL) throws {
        for (index, gen) in generations.enumerated() {
            for part in ["", "-wal", "-shm"] {
                let url = dir.appendingPathComponent("\(base)\(part).\(gen)")
                try Data("x".utf8).write(to: url)
                // 世代の新しさを作成日時で表す（先に並べたものほど古い）。
                let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
                try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
            }
        }
    }

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("世代単位で刈る（現役世代の WAL/SHM を巻き添えにしない）")
    func prunesByGeneration() throws {
        let dir = try tempDirectory()
        let base = "BackupKit.store"
        let store = dir.appendingPathComponent(base)
        try Data("live".utf8).write(to: store)                    // 現役のストア
        try makeQuarantines(generations: ["corrupt", "corrupt2", "corrupt3", "corrupt4"],
                            base: base, in: dir)

        pruneQuarantines(of: store, keep: 3)

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names.contains(base), "現役のストアを消してはいけない")
        for gen in ["corrupt2", "corrupt3", "corrupt4"] {
            for part in ["", "-wal", "-shm"] {
                #expect(names.contains("\(base)\(part).\(gen)"),
                        "残すべき世代のファイル \(base)\(part).\(gen) が消えた")
            }
        }
        for part in ["", "-wal", "-shm"] {
            #expect(!names.contains("\(base)\(part).corrupt"),
                    "最古世代の \(base)\(part).corrupt が残った（WAL/SHM が溜まり続ける）")
        }
    }

    @Test("上限内なら何も消さない")
    func keepsEverythingWithinLimit() throws {
        let dir = try tempDirectory()
        let base = "BackupKit.store"
        let store = dir.appendingPathComponent(base)
        try makeQuarantines(generations: ["corrupt", "corrupt2"], base: base, in: dir)

        pruneQuarantines(of: store, keep: 3)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 6)
    }

    @Test("別ストアの退避には触らない")
    func unrelatedStoresAreUntouched() throws {
        let dir = try tempDirectory()
        let base = "BackupKit.store"
        let store = dir.appendingPathComponent(base)
        try makeQuarantines(generations: ["corrupt", "corrupt2", "corrupt3", "corrupt4"],
                            base: base, in: dir)
        try makeQuarantines(generations: ["corrupt"], base: "AutoAlbumV10.store", in: dir)

        pruneQuarantines(of: store, keep: 3)

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names.contains("AutoAlbumV10.store.corrupt"), "別ストアの退避を消した")
        #expect(names.contains("AutoAlbumV10.store-wal.corrupt"))
    }
}
