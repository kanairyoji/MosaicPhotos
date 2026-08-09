import Foundation
import Testing
@testable import MosaicSupport

/// 順番回し（飢餓防止）の不変条件（ADR-87）。
/// 本プロジェクトは同じ飢餓バグを 3 度踏んだ（ADR-72/85/86）ので、
/// 「譲り続けたら必ず順番が回る」ことをテストで固定する。
@Suite("TurnTaking")
struct TurnTakingTests {

    @Test("残作業が無ければ順番を取らない・譲り回数も増えない")
    func noWorkNoTurn() {
        let r = TurnTaking.nextTurn(hasWork: false, blockedByOther: true, streak: 2, maxDeferrals: 3)
        #expect(!r.take)
        #expect(r.streak == 2)   // 増やさない（次に作業が来たとき不当に優先されないため）
    }

    @Test("誰も邪魔していなければ素直に取る（譲り回数はリセット）")
    func takesTurnWhenUnblocked() {
        let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: false, streak: 2, maxDeferrals: 3)
        #expect(r.take)
        #expect(r.streak == 0)
    }

    @Test("上限に達するまでは譲る")
    func defersUntilLimit() {
        var streak = 0
        for _ in 0..<3 {
            let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: true,
                                        streak: streak, maxDeferrals: 3)
            #expect(!r.take)
            streak = r.streak
        }
        #expect(streak == 3)
    }

    @Test("上限に達したら邪魔されていても必ず取る（飢餓防止の核心）")
    func takesTurnAtLimit() {
        let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: true, streak: 3, maxDeferrals: 3)
        #expect(r.take)
        #expect(r.streak == 0)
    }

    /// **不変条件**: 相手が永久に終わらなくても、`maxDeferrals + 1` 窓以内に必ず順番が来る。
    /// ADR-72/85/86 はいずれもこの性質が無く、数週間〜永久に順番が来なかった。
    @Test("永久にブロックされ続けても maxDeferrals+1 窓以内に必ず回ってくる")
    func neverStarves() {
        for maxDeferrals in 0...5 {
            var streak = 0
            var tookTurnAt: Int?
            for window in 0..<(maxDeferrals + 1) {
                let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: true,   // 相手は永久に終わらない
                                            streak: streak, maxDeferrals: maxDeferrals)
                streak = r.streak
                if r.take { tookTurnAt = window; break }
            }
            #expect(tookTurnAt != nil, "maxDeferrals=\(maxDeferrals) で順番が回ってこない＝飢餓")
        }
    }

    /// 長期シミュレーション: 100 窓のうち、ブロックされ続けても一定割合は必ず取れる。
    @Test("100 窓の連続実行で、ブロックされ続けても約 1/(max+1) の割合で順番が回る")
    func fairShareOverManyWindows() {
        var streak = 0
        var taken = 0
        for _ in 0..<100 {
            let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: true, streak: streak, maxDeferrals: 3)
            streak = r.streak
            if r.take { taken += 1 }
        }
        #expect(taken == 25)   // 4 窓に 1 回（3 回譲って 4 回目に取る）
    }

    /// 実バグの再現（ADR-85）: シーンタグが常に残作業を持ち、埋め込みが譲り続ける状況。
    /// 上限が無い（＝旧実装）と永久に取れないことを、上限 0 と大きい値の対比で示す。
    @Test("実バグの形: 相手が終わらないとき、上限が小さいほど早く順番が来る")
    func historicalStarvationShape() {
        func windowsUntilTurn(maxDeferrals: Int) -> Int {
            var streak = 0
            for window in 0..<1000 {
                let r = TurnTaking.nextTurn(hasWork: true, blockedByOther: true,
                                            streak: streak, maxDeferrals: maxDeferrals)
                streak = r.streak
                if r.take { return window }
            }
            return .max   // 1000 窓回っても取れない＝飢餓
        }
        #expect(windowsUntilTurn(maxDeferrals: 0) == 0)    // 即座に取る
        #expect(windowsUntilTurn(maxDeferrals: 3) == 3)    // 現行設定
        #expect(windowsUntilTurn(maxDeferrals: 10) == 10)  // 上限が大きくても有限
    }
}
