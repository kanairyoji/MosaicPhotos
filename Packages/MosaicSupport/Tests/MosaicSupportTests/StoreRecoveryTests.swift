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
}
