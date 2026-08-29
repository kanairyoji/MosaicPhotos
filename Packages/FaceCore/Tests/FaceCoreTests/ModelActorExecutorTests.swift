import Foundation
import Testing
@testable import FaceCore

/// `FaceStore` がメインスレッドで走らないこと（実機 diagnostics-64: レビュー候補の生成で
/// 5.9 秒の前面ハング。ハング中のメインスレッドのスタックに `FaceStore.faceDigestsByCluster`
/// がそのまま写っていた）。理由と罠の形は AutoAlbumCore 側の同名テストに詳述。
@MainActor
struct ModelActorExecutorTests {

    @Test("FaceStore は MainActor から呼んでもメインスレッドで実行しない")
    func faceStoreRunsOffMain() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let onMain = await store.runsOnMainThreadForTesting()
        #expect(onMain == false)
    }
}
