import Foundation
import Testing
@testable import MosaicSupport

/// diagnostics-81 の回帰: **背面では「サムネ取得中」を理由に解析を止めない**。
///
/// 画面が無い時間帯（処理枠・ロック中）に、バックアップ・共有・解析自身のサムネ取得で
/// `cloudThumbnailBusy` が立ち続け、夜間の CLIP 埋め込みが 1 枚も進まなかった。
/// 譲るのは「前面で誰かが見ている間」だけ（ADR-179 を取得経路からゲートへ広げた）。
@Suite("解析が UI へ譲る条件", .serialized)
@MainActor
struct AnalysisYieldGateTests {

    private func reset() {
        BackgroundActivityMonitor.shared.cloudThumbnailBusy = false
        BackgroundActivityMonitor.shared.fullImageBusy = false
        BackgroundActivityMonitor.shared.isViewingPhoto = false
        BackgroundYield.isAppActive = true
    }

    @Test("前面でサムネ取得中なら譲る（従来どおり）")
    func yieldsWhileForegroundFetching() {
        reset()
        BackgroundYield.isAppActive = true
        BackgroundActivityMonitor.shared.cloudThumbnailBusy = true
        #expect(BackgroundYield.analysisShouldYieldToUI)
        reset()
    }

    @Test("背面ならサムネ取得中でも譲らない（窓を捨てない）")
    func doesNotYieldInBackgroundForThumbnails() {
        reset()
        BackgroundYield.isAppActive = false
        BackgroundActivityMonitor.shared.cloudThumbnailBusy = true
        BackgroundActivityMonitor.shared.fullImageBusy = true
        #expect(BackgroundYield.analysisShouldYieldToUI == false,
                "背面で「サムネ取得中」を理由に解析が止まっている（diagnostics-81）")
        reset()
    }

    @Test("背面の判定はメモリ圧迫だけに従う（jetsam の保護は外さない）")
    func backgroundFollowsMemoryPressureOnly() {
        reset()
        BackgroundYield.isAppActive = false
        BackgroundActivityMonitor.shared.cloudThumbnailBusy = true
        // UI の印をすべて立てても、背面の答えは「メモリ圧迫かどうか」と一致する。
        #expect(BackgroundYield.analysisShouldYieldToUI == MemoryPressureMonitor.shared.isUnderPressure)
        reset()
    }
}
