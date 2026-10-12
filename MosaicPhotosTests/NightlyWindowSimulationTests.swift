import XCTest
@testable import MosaicPhotos

/// **夜の窓を模して回し、「順番が回ったか」で測る**（ADR-274）。
///
/// ⚠️⚠️ assert は**最初は 2 つだけ**にしてある（模型を太らせない）:
/// 1. `everyWindow` を宣言した手は、**実測で最短の窓（21 秒）でも**順番が回る
///    → ADR-270（手が一度も走らない）・ADR-273（短い窓でバックアップが進まない）が出る
/// 2. 残作業は**減り続ける** → ADR-257（25 時間で 12 枚）が出る
final class NightlyWindowSimulationTests: XCTestCase {

    private func simulator(captureDateBacklog: Int = 100_000,
                           provideShare: Bool = false,
                           publishAnalysis: Bool = false) -> NightlyWindowSimulator {
        var sim = NightlyWindowSimulator(
            world: .init(captureDateBacklog: captureDateBacklog,
                         embedBacklog: 0, faceBacklog: 0))
        sim.provideShareEnabled = provideShare
        sim.publishAnalysisEnabled = publishAnalysis
        return sim
    }

    // MARK: - 1. 飢餓（ADR-270 / ADR-273 がここで出る）

    /// ⚠️⚠️ **実測で最短の窓（21 秒）でも、毎窓走るべき手には順番が回ること。**
    ///
    /// これが落ちるのは次のどちらか——**どちらも実際に起きた**:
    /// - 並びが悪い（上限のない手の後ろに置いた）＝ADR-270
    /// - 性質の宣言が誤り（投げっぱなしの手を「上限なし」と書いた）＝ADR-273
    func testEveryWindowStepsGetATurnEvenInTheShortestObservedWindow() {
        let shortest = NightlyWindowSimulator.measuredWindowSeconds.min()!
        XCTAssertEqual(shortest, 21, "実測の最短が変わった（窓の実測を更新した？）")

        // 設定の組み合わせを変えても成り立つこと（提供オン＝`shareSync` が並ぶ構成を必ず含む）。
        // ⚠️ 照合の期限が来た週は**除く**——照合は上限なしなので、その後ろに回る
        //    `backup` は短い窓で飢え得る（ADR-206 が認めた 52 回に 1 回の代償）。
        //    そこは `testEveryWindowStepsGetATurnOnReconcileWeeks` が「飢えるのは
        //    `backup` だけ」として別に固定する。
        for provide in [false, true] {
            for publish in [false, true] {
                var sim = simulator(provideShare: provide, publishAnalysis: publish)
                sim.runWindow(seconds: shortest, reconcileDue: false)
                let starved = sim.starvedEveryWindowSteps()
                XCTAssertTrue(starved.isEmpty, """
                    最短の窓（\(Int(shortest)) 秒）で順番が回らなかった手: \(starved)
                    [provide=\(provide) publish=\(publish)]
                    ⚠️ 並びが悪いか、性質の宣言が誤っている。
                    - 上限のない手の後ろに置いていないか（ADR-270）
                    - 投げっぱなしの手を `.unbounded` と宣言していないか（ADR-273）
                    """)
            }
        }
    }

    /// ⚠️ 実測の**どの長さの窓でも**成り立つこと（21〜284 秒を全部掃く）。
    func testEveryWindowStepsGetATurnAcrossTheWholeMeasuredRange() {
        for length in NightlyWindowSimulator.measuredWindowSeconds {
            var sim = simulator(provideShare: true, publishAnalysis: true)
            sim.runWindow(seconds: length)
            XCTAssertTrue(sim.starvedEveryWindowSteps().isEmpty,
                          "窓 \(Int(length)) 秒で飢えた手: \(sim.starvedEveryWindowSteps())")
        }
    }

    /// ⚠️ 照合の期限が来た週も飢えないこと（照合は上限なしなので、後ろの手を食い得る）。
    /// ⚠️ **ここは今の実装では成り立たない可能性がある**ので、成り立たなければ
    /// 「照合の週だけは許す」ことを**明示して**記録する（黙って緩めない）。
    func testEveryWindowStepsGetATurnOnReconcileWeeks() {
        var starvedByLength: [Int: Set<NightlyPlan.Kind>] = [:]
        for length in NightlyWindowSimulator.measuredWindowSeconds {
            var sim = simulator(provideShare: true, publishAnalysis: true)
            sim.runWindow(seconds: length, reconcileDue: true)
            let starved = sim.starvedEveryWindowSteps()
            if !starved.isEmpty { starvedByLength[Int(length)] = starved }
        }
        // ⚠️ 照合（週 1・上限なし）の後ろに回る `backup` は、短い窓では飢え得る
        //    ——ADR-206 が「52 回に 1 回なので、ふだんの手順は変えない」と認めた代償。
        //    飢えるのが `backup` **だけ**であることを固定する（他が飢えたら設計の誤り）。
        for (length, starved) in starvedByLength {
            XCTAssertEqual(starved, [.backup], """
                照合の週に飢えた手が `backup` 以外にある（窓 \(length) 秒）: \(starved)
                ⚠️ 照合の後ろに回るのは `backup` だけのはず（ADR-206 の代償）。
                """)
        }
    }

    // MARK: - 2. 残作業が減り続けること（ADR-257 がここで出る）

    /// ⚠️⚠️ **撮影日時の残りが減り続けること**（ADR-257）。
    ///
    /// 実機では 25 時間・11 起動で **12 枚**しか進まなかった
    /// ——前面のついでだけで、背面の枠から呼ばれていなかったから。
    /// 数晩回して「ほとんど減らない」が出れば、同じ欠陥が出荷前に分かる。
    func testCaptureDateBacklogKeepsShrinkingAcrossNights() {
        var sim = simulator(captureDateBacklog: 100_000)
        let before = sim.world.captureDateBacklog
        sim.runNights(3, windowsPerNight: 3)
        let after = sim.world.captureDateBacklog

        let progressed = before - after
        // 3 晩 × 3 窓 × 500 枚 = 4,500 枚が上限。少なくともその半分は進むこと。
        XCTAssertGreaterThan(progressed, 2_000, """
                3 晩で \(progressed) 枚しか進まなかった（残り \(after)）。
                ⚠️ 実機で 25 時間に 12 枚だったのと同じ形（ADR-257）——
                枠から呼ばれていないか、窓を食う手の後ろに置かれている。
                """)
    }

    /// ⚠️ 回線が無い夜は進まないが、**回線がある夜に再開すること**
    /// （「回線が無いと落とす」が永久の停止になっていないか）。
    func testProgressResumesAfterNightsWithoutNetwork() {
        var sim = simulator(captureDateBacklog: 10_000)
        sim.networkAllowed = false
        sim.runNights(2, windowsPerNight: 3)
        XCTAssertEqual(sim.world.captureDateBacklog, 10_000, "回線が無いのに進んだ")

        sim.networkAllowed = true
        sim.runNights(2, windowsPerNight: 3)
        XCTAssertLessThan(sim.world.captureDateBacklog, 10_000,
                          "回線が戻っても再開しない（落とすだけで戻らない）")
    }

    // MARK: - 模型そのものの確かめ（空振りを防ぐ）

    /// ⚠️ **模型が本当に窓で打ち切っていること**。
    /// これが無いと、上の assert は「全部走るのが当たり前」の世界で通ってしまう（空振り）。
    func testTheSimulationActuallyRunsOutOfTime() {
        var short = simulator(provideShare: true, publishAnalysis: true)
        short.runWindow(seconds: 21)
        var long = simulator(provideShare: true, publishAnalysis: true)
        long.runWindow(seconds: 284)

        XCTAssertFalse(short.world.missedLastWindow.isEmpty, """
                21 秒の窓で 1 手も取りこぼさなかった＝窓の打ち切りが効いていない（模型の誤り）。
                """)
        // ⚠️ 短い窓の方が取りこぼしが**多い**こと（模型の向き）。
        XCTAssertGreaterThanOrEqual(short.world.missedLastWindow.count,
                                    long.world.missedLastWindow.count,
                                    "短い窓の方が取りこぼしが少ない＝模型が逆向き")
        // ⚠️⚠️ **「長い窓なら全部走る」とは assert しない**。この模型は
        // `.unbounded` を「残り全部」と見るので、**最初の上限なしの手より後ろは
        // どの長さでも走らない**——それがこの設計の言い分そのもの（だから上限つきを先に出す）。
        // 模型が主張できるのは `everyWindow` の手が走ること（上の 2 本）だけ。
        XCTAssertTrue(long.starvedEveryWindowSteps().isEmpty,
                      "284 秒あっても毎窓の手が飢えた: \(long.starvedEveryWindowSteps())")
    }

    /// ⚠️ `everyWindow` を宣言した手が 1 つも無ければ、飢餓の assert は**空振り**する。
    func testSomeStepsActuallyDeclareEveryWindow() {
        let declared = NightlyPlan.Kind.allCases.filter { NightlyPlan.spec(for: $0).everyWindow }
        XCTAssertGreaterThanOrEqual(declared.count, 4,
                                    "毎窓走るべき手の宣言が少なすぎる: \(declared)")
        XCTAssertTrue(declared.contains(.backup), "バックアップは毎窓（ADR-180）")
        XCTAssertTrue(declared.contains(.indexSnapshot), "控えの書き直しは毎窓（ADR-266）")
    }
}
