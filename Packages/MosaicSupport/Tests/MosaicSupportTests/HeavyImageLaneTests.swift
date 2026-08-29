import Foundation
import Testing
@testable import MosaicSupport

/// 低優先レーンの「UI へ譲る」は**打ち切られる**こと（ADR-131）。
///
/// 実害: `isUIBusySnapshot` にはクラウドサムネのドレイン中（`cloudThumbnailBusy`）が入り、
/// 数万枚のライブラリでは分単位で立ちっぱなしになる。無制限に譲る実装だと、その間に開いた
/// 画面（顔の管理・代表写真を選ぶ）の画像が**1 枚も出ない**。譲りは操作の瞬間を守るためのもので、
/// 表示を諦めるためのものではない。
@Suite("HeavyImageLane yields are bounded", .serialized)
struct HeavyImageLaneTests {

    @Test("UI がビジーのままでも body は走る（譲りは上限で打ち切る）")
    func yieldIsBounded() async {
        await MainActor.run { BackgroundActivityMonitor.shared.cloudThumbnailBusy = true }
        // fixture の前提を assert する（ビジーになっていないと、何も検証していないことになる）。
        #expect(BackgroundActivityMonitor.isUIBusySnapshot)

        let start = Date()
        let ran = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await HeavyImageLane.run(maxYieldSeconds: 0.4) { true } }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false   // 打ち切りが効いていなければ、こちらが先に返る
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let elapsed = Date().timeIntervalSince(start)
        await MainActor.run { BackgroundActivityMonitor.shared.cloudThumbnailBusy = false }

        #expect(ran)
        #expect(elapsed < 2)
    }
}
