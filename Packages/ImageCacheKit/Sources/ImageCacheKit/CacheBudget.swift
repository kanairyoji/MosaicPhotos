import Foundation

// MARK: - 予算（ADR-185）

/// アプリ全体のディスクキャッシュ予算。キャッシュごとの上限は持たず、**1 つの予算を全キャッシュが共有**する。
///
/// 既定は端末の総容量の 10%（設定で 5% / 20% / 固定 GB に変えられる）。
/// 空き容量が `reserveBytes` を切る手前で予算を縮める（安全弁）。
public enum CacheBudget {

    /// 既定の割合（%）。
    public static let defaultPercent = 10
    /// 選べる割合。
    public static let percentChoices = [5, 10, 20, 30, 40]
    /// 選べる固定値（GB）。
    public static let fixedGBChoices = [2, 5, 10, 20, 50, 100]
    /// 空き容量をこれ以上は食わない。
    public static let reserveBytes = 2 * 1024 * 1024 * 1024
    /// 予算の下限（極端に小さい端末でも最低これだけは使う）。
    public static let floorBytes = 500 * 1024 * 1024

    /// 設定（UserDefaults）。`fixedGB > 0` なら固定、そうでなければ割合。
    public struct Setting: Equatable, Sendable {
        public var percent: Int
        public var fixedGB: Int
        public init(percent: Int = CacheBudget.defaultPercent, fixedGB: Int = 0) {
            self.percent = percent; self.fixedGB = fixedGB
        }
        public var isFixed: Bool { fixedGB > 0 }
    }

    public enum Keys {
        public static let percent = "cacheBudget.percent"
        public static let fixedGB = "cacheBudget.fixedGB"
    }

    public static func setting(_ defaults: UserDefaults = .standard) -> Setting {
        let p = defaults.integer(forKey: Keys.percent)
        let g = defaults.integer(forKey: Keys.fixedGB)
        return Setting(percent: p > 0 ? p : defaultPercent, fixedGB: max(0, g))
    }

    public static func save(_ setting: Setting, _ defaults: UserDefaults = .standard) {
        defaults.set(setting.percent, forKey: Keys.percent)
        defaults.set(setting.fixedGB, forKey: Keys.fixedGB)
    }

    /// 名目の予算（安全弁を掛ける前）。総容量が読めない（0）ときは下限。
    public static func nominalBytes(setting: Setting, totalCapacity: Int) -> Int {
        if setting.isFixed { return max(setting.fixedGB * 1024 * 1024 * 1024, floorBytes) }
        guard totalCapacity > 0 else { return floorBytes }
        return max(Int(Double(totalCapacity) * Double(setting.percent) / 100), floorBytes)
    }

    /// 実効予算: 「いまの使用量＋空き − 予備」を超えない（キャッシュで端末を満杯にしない）。
    /// 空きが読めないときは名目のまま。
    public static func effectiveBytes(nominal: Int, usage: Int, free: Int?) -> Int {
        guard let free else { return nominal }
        return max(min(nominal, usage + free - reserveBytes), floorBytes)
    }

    // MARK: 容量の取得

    /// Caches のあるボリュームの総容量・空き（重要用途向け）。
    public static func volumeCapacity() -> (total: Int?, free: Int?) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let values = try? caches.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeTotalCapacity, values?.volumeAvailableCapacityForImportantUsage.map(Int.init))
    }
}

// MARK: - 層（どれから捨てるか）

/// 予算を超えたときに捨てる順。数字の大きい層から捨てる。
public enum CacheBudgetTier: Int, Sendable, Comparable, CaseIterable {
    /// サムネイル（端末・Dropbox）。小さく・常時使い・解析にも要る。最後まで守る。
    case thumbnails = 1
    /// 派生物（顔アバター等）。サムネから作り直せる。
    case derived = 2
    /// 本体画像（Dropbox のフル画像）。1 件が大きく、再取得は 1 回のタップ。最初に捨てる。
    case fullImages = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// 層ごとの床（予算に対する割合）。ここまで痩せたら次の層へ。
    public var floorFraction: Double {
        switch self {
        case .thumbnails: return 0.50
        case .derived:    return 0.02
        case .fullImages: return 0.10
        }
    }
}

// MARK: - 追い出し計画（純ロジック・テスト対象）

/// 予算超過時に「どのキャッシュから何バイト捨てるか」の 1 手を決める。
/// 協調役（`CacheBudgetCoordinator`）が 1 手ずつ実行し、状態を取り直して繰り返す。
public enum CacheBudgetPlanner {

    public struct Participant: Equatable, Sendable {
        public let id: String
        public let tier: CacheBudgetTier
        public let usage: Int
        /// 最も古く触った時刻（空なら nil）。同じ層の中で、古い方から捨てる。
        public let oldestAccess: Date?
        public init(id: String, tier: CacheBudgetTier, usage: Int, oldestAccess: Date?) {
            self.id = id; self.tier = tier; self.usage = usage; self.oldestAccess = oldestAccess
        }
    }

    public struct Step: Equatable, Sendable {
        public let id: String
        public let bytes: Int
    }

    /// 1 手の最大バイト数（大きすぎると 1 つのキャッシュを空にしてから次へ行き、LRU の粒度が粗くなる）。
    public static let chunkBytes = 64 * 1024 * 1024

    /// 次に捨てる 1 手。超過していなければ nil。
    ///
    /// 規則: 数字の大きい層から。層の合計がその層の床（予算 × 割合）を割るなら次の層へ。
    /// 同じ層の中では**最も古く触ったキャッシュ**から `chunkBytes` ずつ。
    public static func nextStep(budget: Int, participants: [Participant]) -> Step? {
        let total = participants.reduce(0) { $0 + $1.usage }
        let over = total - budget
        guard over > 0 else { return nil }
        for tier in CacheBudgetTier.allCases.sorted(by: >) {
            let members = participants.filter { $0.tier == tier && $0.usage > 0 }
            guard !members.isEmpty else { continue }
            let tierTotal = members.reduce(0) { $0 + $1.usage }
            let floor = Int(Double(budget) * tier.floorFraction)
            let room = tierTotal - floor
            guard room > 0 else { continue }
            // 古い順（時刻が無い＝古いとみなす）。
            let victim = members.min { a, b in
                (a.oldestAccess ?? .distantPast) < (b.oldestAccess ?? .distantPast)
            }!
            let bytes = min(over, room, victim.usage, chunkBytes)
            return Step(id: victim.id, bytes: bytes)
        }
        // どの層も床まで痩せている＝これ以上は捨てない（予算の方が小さすぎる）。
        return nil
    }
}

// MARK: - 参加者

/// 予算に参加するキャッシュが実装する。各キャッシュは自分の LRU で捨てる手段を持ち、
/// 「いくら捨てるか」だけを協調役から受け取る。
public protocol BudgetedCache: AnyObject, Sendable {
    var budgetID: String { get }
    var budgetTier: CacheBudgetTier { get }
    func budgetUsage() async -> Int
    func budgetOldestAccess() async -> Date?
    /// 古い順に `bytes` ぶん捨てる。実際に減った量を返す（0 なら手詰まり）。
    func budgetEvict(bytes: Int) async -> Int
}

// MARK: - 協調役

/// 全キャッシュの合計を予算に収める（ADR-185）。
///
/// 各キャッシュは書き込みのたびに `noteGrowth()` を呼ぶだけ。協調役はまとめて（数秒に 1 回）
/// 合計を見て、超過分を `CacheBudgetPlanner` の順で捨てさせる。書き込みごとに容量判定を
/// していた旧実装（Dropbox は毎回 6.8 万行の fetch）より軽い。
public actor CacheBudgetCoordinator {

    public static let shared = CacheBudgetCoordinator()

    private var participants: [BudgetedCache] = []
    private var pendingRebalance: Task<Void, Never>?
    private var isRebalancing = false
    /// 空きの再確認の間隔（毎回ファイルシステムを叩かない）。
    private var capacity: (total: Int?, free: Int?, at: Date)?

    public struct Snapshot: Sendable {
        public struct Entry: Sendable {
            public let id: String
            public let tier: CacheBudgetTier
            public let usage: Int
        }
        public let setting: CacheBudget.Setting
        public let nominalBudget: Int
        public let effectiveBudget: Int
        public let entries: [Entry]
        public var totalUsage: Int { entries.reduce(0) { $0 + $1.usage } }
    }

    public init() {}

    public func register(_ cache: BudgetedCache) {
        guard !participants.contains(where: { $0.budgetID == cache.budgetID }) else { return }
        participants.append(cache)
    }

    /// 書き込みのあとに呼ぶ（安価・まとめて処理）。
    public nonisolated func noteGrowth() {
        Task { await self.scheduleRebalance(after: 3) }
    }

    private func scheduleRebalance(after seconds: Double) {
        guard pendingRebalance == nil else { return }
        pendingRebalance = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            await self.clearPending()
            await self.rebalance()
        }
    }

    private func clearPending() { pendingRebalance = nil }

    /// 現在の予算。
    public func budgetBytes() -> Int {
        let cap = refreshedCapacity()
        return CacheBudget.nominalBytes(setting: CacheBudget.setting(), totalCapacity: cap.total ?? 0)
    }

    private func refreshedCapacity() -> (total: Int?, free: Int?) {
        if let capacity, Date().timeIntervalSince(capacity.at) < 30 { return (capacity.total, capacity.free) }
        let cap = CacheBudget.volumeCapacity()
        capacity = (cap.total, cap.free, Date())
        return cap
    }

    /// 合計を予算に収める。捨てた総量を返す。
    @discardableResult
    public func rebalance() async -> Int {
        guard !isRebalancing else { return 0 }
        isRebalancing = true
        defer { isRebalancing = false }
        var evicted = 0
        for _ in 0..<200 {   // 64MB × 200 = 12.8GB を 1 回の上限に（暴走防止）
            var entries: [CacheBudgetPlanner.Participant] = []
            for p in participants {
                entries.append(.init(id: p.budgetID, tier: p.budgetTier,
                                     usage: await p.budgetUsage(),
                                     oldestAccess: await p.budgetOldestAccess()))
            }
            let usage = entries.reduce(0) { $0 + $1.usage }
            let cap = refreshedCapacity()
            let budget = CacheBudget.effectiveBytes(
                nominal: CacheBudget.nominalBytes(setting: CacheBudget.setting(), totalCapacity: cap.total ?? 0),
                usage: usage, free: cap.free)
            guard let step = CacheBudgetPlanner.nextStep(budget: budget, participants: entries),
                  let victim = participants.first(where: { $0.budgetID == step.id }) else { break }
            let removed = await victim.budgetEvict(bytes: step.bytes)
            guard removed > 0 else { break }   // 手詰まり（消せない）なら止める
            evicted += removed
            capacity = nil   // 空きが変わった
        }
        return evicted
    }

    /// 設定画面用。
    public func snapshot() async -> Snapshot {
        var entries: [Snapshot.Entry] = []
        for p in participants {
            entries.append(.init(id: p.budgetID, tier: p.budgetTier, usage: await p.budgetUsage()))
        }
        let cap = refreshedCapacity()
        let setting = CacheBudget.setting()
        let nominal = CacheBudget.nominalBytes(setting: setting, totalCapacity: cap.total ?? 0)
        let usage = entries.reduce(0) { $0 + $1.usage }
        return Snapshot(setting: setting, nominalBudget: nominal,
                        effectiveBudget: CacheBudget.effectiveBytes(nominal: nominal, usage: usage, free: cap.free),
                        entries: entries)
    }
}
