import Testing
@testable import MosaicSupport

@Suite("MemoryBudget")
struct MemoryBudgetTests {
    private let mb = 1_048_576

    @Test("低RAM予算は下限(60MB)にクランプ")
    func clampsToFloor() {
        // 1GB の 5% ≈ 53MB → 下限 60MB
        let cost = MemoryBudget.thumbnailCostLimit(budget: UInt64(1) * 1_073_741_824)
        #expect(cost == 60 * mb)
    }

    @Test("高RAM予算は上限(192MB)にクランプ")
    func clampsToCeiling() {
        // 8GB の 5% ≈ 410MB → 上限 192MB
        let cost = MemoryBudget.thumbnailCostLimit(budget: UInt64(8) * 1_073_741_824)
        #expect(cost == 192 * mb)
    }

    @Test("中間予算は割合(約5%)で決まる")
    func scalesInRange() {
        // 2GB の 5% ≈ 107MB（下限60〜上限192 の範囲内）
        let cost = MemoryBudget.thumbnailCostLimit(budget: UInt64(2) * 1_073_741_824)
        #expect(cost > 60 * mb && cost < 192 * mb)
        #expect(cost == Int(Double(UInt64(2) * 1_073_741_824) * 0.05))
    }

    @Test("override で予算を固定注入できる")
    func overrideInjects() {
        MemoryBudget.override = UInt64(3) * 1_073_741_824
        defer { MemoryBudget.override = nil }
        #expect(MemoryBudget.availableBytes() == UInt64(3) * 1_073_741_824)
    }
}
