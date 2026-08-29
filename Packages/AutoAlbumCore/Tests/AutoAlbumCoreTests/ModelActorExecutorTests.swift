import Foundation
import Testing
@testable import AutoAlbumCore

/// **SwiftData ストアがメインスレッドで走らないこと**の回帰テスト（実機 diagnostics-64/65）。
///
/// ⚠️ 罠の形: SwiftData の既定 executor（`DefaultSerialModelExecutor`）はジョブを
/// **呼び出したスレッドでそのまま実行する**。つまり `@ModelActor` でも、MainActor から
/// `await store.…` と書けば fetch は**メインスレッドで走る**。`await` があるので
/// コードの見た目はオフメインそのもので、レビューでも気づけない。実機では
/// `allEnrichedPhotosLite()`（86k 件）が **10.9 秒の前面ハング**になった。
///
/// ⚠️ 「init したスレッドに束縛される」は**誤り**（長らくそう理解していた）。生成を
/// `Task.detached` に移しても、呼び出し元がメインならメインで走る。だから
/// `unownedExecutor` を専用キューへ差し替える形でしか断てない——このテストはそれを固定する。
/// 差し替えを消すと（`unownedExecutor` を削ると）このテストは落ちる。
@MainActor
struct ModelActorExecutorTests {

    @Test("AutoAlbumStore は MainActor から呼んでもメインスレッドで実行しない")
    func autoAlbumStoreRunsOffMain() async {
        // 生成もあえてメインで行う（生成スレッドは無関係だと示すため）。
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let onMain = await store.runsOnMainThreadForTesting()
        #expect(onMain == false)
    }

    @Test("TagStore は MainActor から呼んでもメインスレッドで実行しない")
    func tagStoreRunsOffMain() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        let onMain = await store.runsOnMainThreadForTesting()
        #expect(onMain == false)
    }

    @Test("UsageStore は MainActor から呼んでもメインスレッドで実行しない")
    func usageStoreRunsOffMain() async {
        let store = UsageStore(isStoredInMemoryOnly: true)
        let onMain = await store.runsOnMainThreadForTesting()
        #expect(onMain == false)
    }
}
