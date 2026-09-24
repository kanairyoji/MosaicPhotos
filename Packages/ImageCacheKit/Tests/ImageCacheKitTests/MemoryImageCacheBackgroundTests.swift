#if canImport(UIKit)
import Testing
import UIKit
@testable import ImageCacheKit

/// **背面では画像を抱えない**（ADR-226）。
///
/// ⚠️ サムネのメモリ上限は端末の予算の約 5%（60〜192MB）で、クラウドと端末の 2 系統ある。
/// 背面では誰も見ていないのに抱えたままで、背面のアプリは footprint の大きい順に落とされる。
@Suite("画像キャッシュの背面モード（ADR-226）", .serialized)
@MainActor
struct MemoryImageCacheBackgroundTests {

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    @Test("背面へ入ると上限が下限まで下がり、戻ると元に戻る")
    func backgroundShrinksAndRestores() {
        let floor = 1 * 1024 * 1024
        let cache = MemoryImageCache(totalCostLimit: 64 * 1024 * 1024, purgeOnCritical: false,
                                     pressureFloor: floor)
        defer { MemoryImageCache.setBackgroundMode(false) }

        MemoryImageCache.setBackgroundMode(true)
        #expect(cache.costLimitForTesting == floor, "背面なのに上限を抱えたまま")

        MemoryImageCache.setBackgroundMode(false)
        #expect(cache.costLimitForTesting == 64 * 1024 * 1024, "前面へ戻っても絞ったまま")
    }

    /// ⚠️ 背面のあいだに圧迫が来ると「一定時間後に元へ戻す」予約が入る。
    /// その復帰で**背面なのに上限が戻る**と、絞った意味が消える。
    @Test("背面中は、圧迫からの復帰でも上限を戻さない")
    func pressureRestoreKeepsFloorWhileBackground() {
        let floor = 1 * 1024 * 1024
        let cache = MemoryImageCache(totalCostLimit: 64 * 1024 * 1024, purgeOnCritical: false,
                                     pressureFloor: floor)
        defer { MemoryImageCache.setBackgroundMode(false) }

        MemoryImageCache.setBackgroundMode(true)
        cache.restoreAfterPressureForTesting()

        #expect(cache.costLimitForTesting == floor, "背面なのに圧迫復帰で上限が戻った")
    }

    @Test("背面のあいだに作ったキャッシュも、最初から絞られている")
    func newCacheJoinsBackgroundMode() {
        defer { MemoryImageCache.setBackgroundMode(false) }
        MemoryImageCache.setBackgroundMode(true)

        let floor = 2 * 1024 * 1024
        let cache = MemoryImageCache(totalCostLimit: 64 * 1024 * 1024, purgeOnCritical: false,
                                     pressureFloor: floor)

        #expect(cache.costLimitForTesting == floor)
    }
}
#endif
