import Foundation
import Testing
@testable import ImageCacheKit

private let GB = 1024 * 1024 * 1024
private let MB = 1024 * 1024

@Suite("CacheBudget（予算）")
struct CacheBudgetTests {

    @Test("既定は総容量の 10%・固定 GB が優先・読めなければ下限")
    func nominal() {
        #expect(CacheBudget.nominalBytes(setting: .init(), totalCapacity: 128 * GB) == Int(Double(128 * GB) * 0.10))
        #expect(CacheBudget.nominalBytes(setting: .init(percent: 20), totalCapacity: 100 * GB) == 20 * GB)
        #expect(CacheBudget.nominalBytes(setting: .init(percent: 10, fixedGB: 5), totalCapacity: 100 * GB) == 5 * GB, "固定が優先")
        #expect(CacheBudget.nominalBytes(setting: .init(), totalCapacity: 0) == CacheBudget.floorBytes)
    }

    @Test("安全弁: 使用中＋空き−予備を超えない。空きが読めなければ名目のまま")
    func effective() {
        #expect(CacheBudget.effectiveBytes(nominal: 10 * GB, usage: 1 * GB, free: 3 * GB) == 2 * GB)
        #expect(CacheBudget.effectiveBytes(nominal: 10 * GB, usage: 1 * GB, free: 50 * GB) == 10 * GB)
        #expect(CacheBudget.effectiveBytes(nominal: 10 * GB, usage: 1 * GB, free: nil) == 10 * GB)
        #expect(CacheBudget.effectiveBytes(nominal: 10 * GB, usage: 0, free: 1 * GB) == CacheBudget.floorBytes, "下限は割らない")
    }
}

@Suite("CacheBudgetPlanner（どれから捨てるか）")
struct CacheBudgetPlannerTests {
    typealias P = CacheBudgetPlanner.Participant
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("超過していなければ何もしない")
    func noStepUnderBudget() {
        let ps = [P(id: "thumbs", tier: .thumbnails, usage: 1 * GB, oldestAccess: t0),
                  P(id: "full", tier: .fullImages, usage: 1 * GB, oldestAccess: t0)]
        #expect(CacheBudgetPlanner.nextStep(budget: 10 * GB, participants: ps) == nil)
    }

    @Test("本体画像 → 派生物 → サムネの順。サムネは他が床まで痩せるまで触らない")
    func tierOrder() {
        let ps = [P(id: "thumbs", tier: .thumbnails, usage: 8 * GB, oldestAccess: t0),
                  P(id: "faces", tier: .derived, usage: 1 * GB, oldestAccess: t0),
                  P(id: "full", tier: .fullImages, usage: 3 * GB, oldestAccess: t0)]
        // 予算 10GB・合計 12GB → 本体画像から 64MB ずつ。
        let step = CacheBudgetPlanner.nextStep(budget: 10 * GB, participants: ps)
        #expect(step?.id == "full")
        #expect(step?.bytes == CacheBudgetPlanner.chunkBytes)
        // 本体画像が床（10%＝1GB）まで痩せたら派生物へ。
        let ps2 = [P(id: "thumbs", tier: .thumbnails, usage: 9 * GB, oldestAccess: t0),
                   P(id: "faces", tier: .derived, usage: 1 * GB, oldestAccess: t0),
                   P(id: "full", tier: .fullImages, usage: 1 * GB, oldestAccess: t0)]
        #expect(CacheBudgetPlanner.nextStep(budget: 10 * GB, participants: ps2)?.id == "faces")
        // 派生物も床（2%＝200MB）まで痩せたらサムネ。
        let ps3 = [P(id: "thumbs", tier: .thumbnails, usage: 9 * GB, oldestAccess: t0),
                   P(id: "faces", tier: .derived, usage: 200 * MB, oldestAccess: t0),
                   P(id: "full", tier: .fullImages, usage: 1 * GB, oldestAccess: t0)]
        #expect(CacheBudgetPlanner.nextStep(budget: 10 * GB, participants: ps3)?.id == "thumbs")
    }

    @Test("同じ層では最も古く触ったキャッシュから（端末とクラウドのサムネを区別しない）")
    func oldestFirstWithinTier() {
        let ps = [P(id: "local", tier: .thumbnails, usage: 5 * GB, oldestAccess: t0.addingTimeInterval(1000)),
                  P(id: "cloud", tier: .thumbnails, usage: 5 * GB, oldestAccess: t0)]
        #expect(CacheBudgetPlanner.nextStep(budget: 9 * GB, participants: ps)?.id == "cloud")
        let flipped = [P(id: "local", tier: .thumbnails, usage: 5 * GB, oldestAccess: t0),
                       P(id: "cloud", tier: .thumbnails, usage: 5 * GB, oldestAccess: t0.addingTimeInterval(1000))]
        #expect(CacheBudgetPlanner.nextStep(budget: 9 * GB, participants: flipped)?.id == "local")
    }

    @Test("床まで痩せたら止まる（予算が小さすぎても空にはしない）")
    func stopsAtFloors() {
        let ps = [P(id: "thumbs", tier: .thumbnails, usage: 480 * MB, oldestAccess: t0),
                  P(id: "full", tier: .fullImages, usage: 50 * MB, oldestAccess: t0)]
        // 予算 500MB・合計 530MB（超過 30MB）・床: サムネ 250MB・本体 50MB
        // → 本体は床ちょうどで触れず、サムネから超過分だけ。
        let step = CacheBudgetPlanner.nextStep(budget: 500 * MB, participants: ps)
        #expect(step?.id == "thumbs")
        #expect(step?.bytes == 30 * MB)
        let atFloor = [P(id: "thumbs", tier: .thumbnails, usage: 250 * MB, oldestAccess: t0),
                       P(id: "full", tier: .fullImages, usage: 50 * MB, oldestAccess: t0),
                       P(id: "other", tier: .derived, usage: 300 * MB, oldestAccess: t0)]
        // 派生物は床（10MB）まで捨てられる。
        #expect(CacheBudgetPlanner.nextStep(budget: 500 * MB, participants: atFloor)?.id == "other")
    }
}

/// 協調役: 参加者に「捨てろ」を配り、合計が予算に収まるまで繰り返す。
@Suite("CacheBudgetCoordinator")
struct CacheBudgetCoordinatorTests {

    private final class FakeCache: BudgetedCache, @unchecked Sendable {
        let budgetID: String
        let budgetTier: CacheBudgetTier
        var usage: Int
        var oldest: Date?
        var evictCalls = 0
        init(_ id: String, _ tier: CacheBudgetTier, usage: Int, oldest: Date?) {
            budgetID = id; budgetTier = tier; self.usage = usage; self.oldest = oldest
        }
        func budgetUsage() async -> Int { usage }
        func budgetOldestAccess() async -> Date? { oldest }
        func budgetEvict(bytes: Int) async -> Int {
            evictCalls += 1
            let removed = min(bytes, usage)
            usage -= removed
            return removed
        }
    }

    @Test("合計が予算を超えたら、本体画像から順に、収まるまで捨てる")
    func rebalancesToBudget() async {
        // 固定 5GB の予算（端末の容量に依存しないよう固定で）。
        let defaults = UserDefaults.standard
        let savedP = defaults.integer(forKey: CacheBudget.Keys.percent)
        let savedG = defaults.integer(forKey: CacheBudget.Keys.fixedGB)
        CacheBudget.save(.init(percent: 10, fixedGB: 5))
        defer { defaults.set(savedP, forKey: CacheBudget.Keys.percent); defaults.set(savedG, forKey: CacheBudget.Keys.fixedGB) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let thumbs = FakeCache("thumbs", .thumbnails, usage: 3 * GB, oldest: t0)
        let full = FakeCache("full", .fullImages, usage: 4 * GB, oldest: t0)
        let coordinator = CacheBudgetCoordinator()
        await coordinator.register(thumbs)
        await coordinator.register(full)

        let evicted = await coordinator.rebalance()
        // 合計 7GB → 5GB（空き容量の安全弁でさらに縮む可能性はあるが、この Mac では 5GB 以下に収まる）。
        #expect(evicted >= 2 * GB)
        #expect(thumbs.usage == 3 * GB, "サムネは触っていない（本体画像に余地があった）")
        #expect(full.usage <= 2 * GB)
        #expect(full.evictCalls >= 1)
    }
}
