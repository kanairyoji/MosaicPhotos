import Foundation
import Testing
@testable import BackupKit

/// `BackupStore` がメインスレッドで走らないこと。理由と罠の形は AutoAlbumCore 側の同名テストに詳述。
@MainActor
struct ModelActorExecutorTests {

    @Test("BackupStore は MainActor から呼んでもメインスレッドで実行しない")
    func backupStoreRunsOffMain() async {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let onMain = await store.runsOnMainThreadForTesting()
        #expect(onMain == false)
    }
}
