import Foundation
import Testing
@testable import MosaicSupport

/// AI 処理タイミング（5段階）の判定ロジック。段階を上げるほど条件が単調に緩むことを固定する。
@Suite("HeavyWorkTiming (5-level gate)")
struct HeavyWorkTimingTests {

    /// 既定シナリオ: 夜間（充電＋Wi-Fi＋非使用）。
    private func allows(_ t: HeavyWorkTiming,
                        power: Bool = true, lowPower: Bool = false,
                        wifi: Bool = true, reachable: Bool = true,
                        active: Bool = false, idle: Bool = false,
                        battery: Float = 1.0,
                        requiresNetwork: Bool = true) -> Bool {
        t.allows(isOnPower: power, isLowPowerMode: lowPower,
                 isOnWiFi: wifi, isReachable: reachable,
                 isAppActive: active, foregroundIdle: idle, batteryLevel: battery,
                 requiresNetwork: requiresNetwork)
    }

    @Test("paused は常に不可（夜間条件が揃っていても）")
    func pausedNeverRuns() {
        #expect(!allows(.paused))
    }

    @Test("nightly: 夜間条件で可・前面では合間でも不可")
    func nightlyRules() {
        #expect(allows(.nightly))
        #expect(!allows(.nightly, active: true, idle: true))    // 前面は合間でも動かない
        #expect(!allows(.nightly, power: false))                // 電源必須
        #expect(!allows(.nightly, wifi: false))                 // Wi-Fi 必須
    }

    @Test("chargeActive: 前面でも操作の合間なら可・タッチ直後は不可")
    func chargeActiveRules() {
        #expect(allows(.chargeActive, active: true, idle: true))
        #expect(!allows(.chargeActive, active: true, idle: false))   // 操作直後
        #expect(!allows(.chargeActive, power: false, active: true, idle: true))   // 電源は必須のまま
    }

    @Test("battery: 電源なしでも可・ただし残量 20% 未満は不可")
    func batteryRules() {
        #expect(allows(.battery, power: false, battery: 0.5))
        #expect(!allows(.battery, power: false, battery: 0.15))   // 残量安全弁
        #expect(allows(.battery, power: true, battery: 0.15))     // 充電中なら残量不問
        #expect(!allows(.battery, power: false, wifi: false))     // Wi-Fi は必須のまま
    }

    @Test("unlimited: モバイル回線でも可・圏外は不可")
    func unlimitedRules() {
        #expect(allows(.unlimited, power: false, wifi: false, reachable: true, battery: 0.5))
        #expect(!allows(.unlimited, power: false, wifi: false, reachable: false, battery: 0.5))
    }

    @Test("ローカル処理(requiresNetwork:false)は Wi-Fi 不要で走る・電源/低電力の安全弁は維持")
    func localWorkIgnoresNetwork() {
        // 端末内写真の顔スキャン・CLIP 埋め込みは通信不要（Fix B）。
        // nightly・充電＋非使用なら Wi-Fi/回線が無くても可。
        #expect(allows(.nightly, wifi: false, reachable: false, requiresNetwork: false))
        // ただし電源・低電力・使用中の安全弁は requiresNetwork に関わらず効く。
        #expect(!allows(.nightly, power: false, wifi: false, requiresNetwork: false))       // 電源必須
        #expect(!allows(.nightly, lowPower: true, wifi: false, requiresNetwork: false))     // 低電力は不可
        #expect(!allows(.nightly, wifi: false, active: true, idle: true, requiresNetwork: false)) // 前面は不可
        // 対照: 回線を要する作業（requiresNetwork:true）は従来どおり Wi-Fi 必須。
        #expect(!allows(.nightly, wifi: false, requiresNetwork: true))
    }

    @Test("低電力モードは全段階で不可（安全弁）")
    func lowPowerBlocksAll() {
        for t in HeavyWorkTiming.allCases {
            #expect(!allows(t, lowPower: true))
        }
    }

    @Test("段階は単調（上の段階は下の段階の許可を全部含む）")
    func monotonicity() {
        // 代表的な状況を総当たりし、level N で可なら level N+1 でも可であることを確認。
        let bools = [false, true]
        for power in bools { for wifi in bools { for reachable in [wifi, true] {
            for active in bools { for idle in bools {
                for battery in [Float(0.1), 0.5, 1.0] {
                    var previous = false
                    for t in HeavyWorkTiming.allCases {
                        let now = allows(t, power: power, wifi: wifi, reachable: reachable,
                                         active: active, idle: idle, battery: battery)
                        if previous {
                            #expect(now, "上の段階は前段階の許可を含むはず: \(t) (power=\(power) wifi=\(wifi) active=\(active) idle=\(idle) battery=\(battery))")
                        }
                        previous = now
                    }
                }
            }}
        }}}
    }
}
