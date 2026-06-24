import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("BackgroundProcessing presets")
struct BackgroundProcessingTests {

    @Test("段階は軽い→重いの順（件数増・休止減）で単調")
    func presetsAreMonotonic() {
        let presets = BackgroundProcessing.presets
        #expect(presets.count >= 3)
        for i in 1..<presets.count {
            #expect(presets[i].batchSize >= presets[i - 1].batchSize)      // 件数は増える
            #expect(presets[i].pauseSeconds <= presets[i - 1].pauseSeconds) // 休止は減る
        }
    }

    @Test("インデックスは範囲外でもクランプされる")
    func clampsOutOfRange() {
        #expect(BackgroundProcessing.preset(at: -5) == BackgroundProcessing.presets.first)
        #expect(BackgroundProcessing.preset(at: 999) == BackgroundProcessing.presets.last)
    }

    @Test("既定インデックスは有効範囲・betweenBatchNs は pauseSeconds と整合")
    func defaultAndNs() {
        let p = BackgroundProcessing.preset(at: BackgroundProcessing.defaultIndex)
        #expect(BackgroundProcessing.presets.contains(p))
        #expect(p.betweenBatchNs == UInt64(p.pauseSeconds * 1_000_000_000))
    }
}
