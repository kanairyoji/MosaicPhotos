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
