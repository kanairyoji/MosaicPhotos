import XCTest
@testable import MosaicPhotos

/// **夜の窓を模して回し、「順番が回ったか」で測る**（ADR-274・追補 2 で全面見直し）。
///
/// ⚠️⚠️ 追補 2 で直したこと（独立レビュー 3 件が同時に指摘した 3 つの穴）:
/// 1. 偽りが**並びの導出に届いていなかった**ので、退行シナリオが名乗った欠陥とは
///    **別の仕組み**で通っていた（→ 偽りを本番の `spec(for:)` seam へ移した）
/// 2. **計画から落ちた手を飢餓に数えていなかった**（→ `requiredEveryWindowSteps` で
///    「並ぶべき集合」を宣言から導く）
/// 3. 模型の歯（`.bounded` の秒数）が**何にも固定されていなかった**ので、
///    変異（撮影日時の定数読みを落とす／上限つきを 0 秒にする）で**全部 green** だった
///    （→ 下の「模型の歯」節で pin）
final class NightlyWindowSimulationTests: XCTestCase {

    private func simulator(captureDateBacklog: Int = 100_000,
                           embedBacklog: Int = 0,
                           provideShare: Bool = false,
                           publishAnalysis: Bool = false,
                           boostActive: Bool = false,
                           networkAllowed: Bool = true) -> NightlyWindowSimulator {
        var sim = NightlyWindowSimulator(
            world: .init(captureDateBacklog: captureDateBacklog,
                         embedBacklog: embedBacklog, faceBacklog: 0))
        sim.provideShareEnabled = provideShare
        sim.publishAnalysisEnabled = publishAnalysis
        sim.boostActive = boostActive
        sim.networkAllowed = networkAllowed
        return sim
    }

    /// ⚠️ **本当に効く軸だけを掃く**。以前は `provideShare × publishAnalysis` の 4 通りを
    /// 回していたが、どちらも最初の上限なしの手より後ろに並ぶので
    /// **4 つとも同一の世界**だった（実測で ran が完全一致・独立レビューの指摘）。
    /// 4 倍の時間で 1 倍の網羅。ここでは並びと計画の中身が本当に変わる軸を列挙する。
    private static let axes: [(name: String, backlog: Int, embed: Int,
                               share: Bool, publish: Bool, boost: Bool, reconcile: Bool)] = {
        var out: [(String, Int, Int, Bool, Bool, Bool, Bool)] = []
        for reconcile in [false, true] {
            for backlog in [0, 100_000] {          // 撮影日時の手が並ぶ／並ばない
                for embed in [0, 50_000] {         // generate が走る／見送られる
                    for boost in [false, true] {   // startAnalysis / skipAnalysisBoostActive
                        for share in [false, true] {
                            out.append(("rec=\(reconcile) backlog=\(backlog) embed=\(embed) "
                                        + "boost=\(boost) share=\(share)",
                                        backlog, embed, share, share, boost, reconcile))
                        }
                    }
                }
            }
        }
        return out
    }()

    // MARK: - 1. 飢餓（ADR-270 / ADR-273 がここで出る）

    /// ⚠️⚠️ **実測のどの窓でも、毎窓走るべき手には順番が回ること。**
    ///
    /// これが落ちるのは次のどれか——**どれも実際に起きた**:
    /// - 並びが悪い（窓を食う手の後ろに置いた）＝ADR-270
    /// - 性質の宣言が誤り（投げっぱなしの手を「上限なし」と書いた）＝ADR-273
    /// - 手が**計画から黙って落ちた**＝ADR-266 / ADR-273 #3
    ///
    /// ⚠️ 照合の週も**例外なく**含める。以前はここで `backup` を手で免除していたが、
    /// 免除は `after`（＝`.reconcile`）と `cost` から**導出できる**ので、
    /// テストのコメントに例外を書くのをやめた（ADR-196: 同じ判断を 2 か所に書かない）。
    func testEveryWindowStepsGetATurnInEveryMeasuredWindowAndConfiguration() {
        var checked = 0
        for axis in Self.axes {
            for length in NightlyWindowSimulator.measuredWindowSeconds {
                var sim = simulator(captureDateBacklog: axis.backlog, embedBacklog: axis.embed,
                                    provideShare: axis.share, publishAnalysis: axis.publish,
                                    boostActive: axis.boost)
                sim.runWindow(seconds: length, reconcileDue: axis.reconcile)
                checked += 1
                XCTAssertTrue(sim.starvedEveryWindowSteps().isEmpty, """
                    窓 \(Int(length)) 秒で順番が回らなかった手: \(sim.starvedEveryWindowSteps())
                    [\(axis.name)]
                    ⚠️ 並びが悪いか、性質の宣言が誤っているか、手が計画から落ちている。
                    - 窓を食う手の後ろに置いていないか（ADR-270）
                    - 投げっぱなしの手を `.unbounded` と宣言していないか（ADR-273）
                    - `applicableSteps` の条件分岐で落としていないか（ADR-266）
                    """)
            }
        }
        // ⚠️ 空振り防止（ADR-119 の作法）: 本当に掃いたことを回数で確かめる。
        XCTAssertEqual(checked, Self.axes.count * NightlyWindowSimulator.measuredWindowSeconds.count)
        XCTAssertGreaterThan(checked, 400, "掃いた構成が少なすぎる＝軸の列挙が壊れている")
    }

    /// ⚠️ **照合の週の免除が、導出として本当に効いていること。**
    ///
    /// ADR-206 は「期限の週はバックアップの**開始が遅れる**」を認めた（52 回に 1 回の代償）。
    /// その免除を手書きのリストにすると、`after` を増やしたときに静かに広がる——
    /// だから `after` の相手が上限なしで同じ窓に居るかで**導く**。
    /// ⚠️ ここが空集合になると上の掃きが「免除で全部通る」に化けるので、
    /// **差が出ていること**を固定する（空でも通る assert を書かない）。
    func testTheReconcileWeekExemptionIsDerivedAndActuallyFires() {
        var sim = simulator(provideShare: true, publishAnalysis: true)

        let normal = NightlyWindowSimulator.requiredEveryWindowSteps(
            in: sim.plan(reconcileDue: false), networkAllowed: true)
        let reconcileWeek = NightlyWindowSimulator.requiredEveryWindowSteps(
            in: sim.plan(reconcileDue: true), networkAllowed: true)

        XCTAssertTrue(normal.contains(.backup), "平常週はバックアップが毎窓（ADR-180）")
        XCTAssertFalse(reconcileWeek.contains(.backup), """
            照合の週に `backup` が免除されていない。
            ⚠️ `after: [.reconcile]` と `reconcile` が `.unbounded` であることから
            導かれるはず（ADR-206 が認めた遅れ）。
            """)
        XCTAssertEqual(normal.subtracting(reconcileWeek), [.backup],
                       "免除されるのは `backup` だけのはず（他が消えたら導出が広すぎる）")

        // 免除された側が本当に走らないことも 1 回だけ確かめる（免除が机上でないこと）。
        sim.runWindow(seconds: 21, reconcileDue: true)
        XCTAssertEqual(sim.world.executed[.backup, default: 0], 0,
                       "照合の週の最短の窓では、バックアップは実際に順番が回らない")
    }

    /// ⚠️ 回線が無い窓では、回線が要る手は**落ちていて正しい**（飢餓ではない）。
    func testOfflineWindowsDoNotReportDroppedNetworkStepsAsStarved() {
        var sim = simulator(provideShare: true, publishAnalysis: true, networkAllowed: false)
        sim.runWindow(seconds: 21)
        XCTAssertTrue(sim.starvedEveryWindowSteps().isEmpty,
                      "回線が無い窓で飢餓を誤報した: \(sim.starvedEveryWindowSteps())")
    }

    // MARK: - 2. 残作業が減り続けること（ADR-257 がここで出る）

    /// ⚠️⚠️ **撮影日時の残りが減り続けること**（ADR-257）。
    ///
    /// 実機では 25 時間・11 起動で **12 枚**しか進まなかった
    /// ——前面のついでだけで、背面の枠から呼ばれていなかったから。
    func testCaptureDateBacklogKeepsShrinkingAcrossNights() {
        var sim = simulator(captureDateBacklog: 100_000)
        let before = sim.world.captureDateBacklog
        sim.runNights(3, windowsPerNight: 3)
        let progressed = before - sim.world.captureDateBacklog

        // 3 晩 × 3 窓 × 500 枚 = 4,500 枚が上限。少なくともその半分は進むこと。
        XCTAssertGreaterThan(progressed, 2_000, """
                3 晩で \(progressed) 枚しか進まなかった（残り \(sim.world.captureDateBacklog)）。
                ⚠️ 実機で 25 時間に 12 枚だったのと同じ形（ADR-257）——
                枠から呼ばれていないか、窓を食う手の後ろに置かれている。
                """)
        // ⚠️ 回数でも測る（ADR-119: 件数ではなく回数）。9 窓すべてで順番が回ること。
        XCTAssertEqual(sim.world.executed[.captureDates, default: 0], 9,
                       "9 窓のうち \(sim.world.executed[.captureDates, default: 0]) 回しか回らなかった")
    }

    /// ⚠️ 回線が無い夜は進まないが、**回線がある夜に再開すること**
    /// （「回線が無いと落とす」が永久の停止になっていないか）。
    func testProgressResumesAfterNightsWithoutNetwork() {
        var sim = simulator(captureDateBacklog: 10_000, networkAllowed: false)
        sim.runNights(2, windowsPerNight: 3)
        XCTAssertEqual(sim.world.captureDateBacklog, 10_000, "回線が無いのに進んだ")
        XCTAssertEqual(sim.world.executed[.captureDates, default: 0], 0)

        sim.networkAllowed = true
        sim.runNights(2, windowsPerNight: 3)
        XCTAssertLessThan(sim.world.captureDateBacklog, 10_000,
                          "回線が戻っても再開しない（落とすだけで戻らない）")
    }

    // MARK: - 3. 模型の歯（これが無いと変異で全部 green になる）

    /// ⚠️⚠️ **模型の識別力は所要の導出から来る。折れても静かなので、ここで全部 pin する。**
    ///
    /// 独立レビューの変異テストで分かったこと（**2 周ぶん**）:
    /// - 上限つきを 0 秒にする → 当時**全部 green**
    /// - 撮影日時の本番定数の読みを落とす → 当時**全部 green**
    /// - ⚠️⚠️ **上限なしを「残り全部」から 1 秒に変える → 2 周目でも全部 green だった**。
    ///   つまり `order` の費用模型が存在する理由そのもの（「上限なしの手は後ろに何も残さない」）が
    ///   **どこにも assert されていなかった**。1 周目の直しは `.bounded` だけ pin していた。
    /// ADR-253（当たらない規則が ✅ の顔で居座る）そのものなので、3 つとも pin する。
    func testTheModelsDiscriminatingPowerIsPinned() {
        // (a) 撮影日時は本番の定数と**一致**すること。
        //     ⚠️ これは「読んでいる」ことの証明にはならない（`return 40` と書き写しても通る）。
        //     検出できるのは「読みを落とした」ことと、後から定数がずれたこと。
        XCTAssertEqual(
            NightlyWindowSimulator.seconds(for: .probeCaptureDates(limit: 500), remaining: 10_000),
            HeavyWorkScheduler.captureDateProbeSeconds,
            "撮影日時の所要が本番の定数と違う（模型の歯が折れている）")

        // (b) 上限つきは 0 秒ではないこと（0 にすると窓が尽きず飢餓が出なくなる）。
        XCTAssertGreaterThan(
            NightlyWindowSimulator.seconds(for: .logStalledPasses, remaining: 10_000), 0,
            "上限つきの手が 0 秒＝窓が尽きないので飢餓を一切検出できない")

        // (c) ⚠️ **並びのテストの死角**: 撮影日時は `.bounded` なのに、
        //     実測で最短の窓より長い。だから `windowEating`（上限なしの一覧）には
        //     入らないのに、後ろに置かれた手は実際に飢える——模型だけがここを見る。
        XCTAssertGreaterThan(
            NightlyWindowSimulator.seconds(for: .probeCaptureDates(limit: 500), remaining: 10_000),
            NightlyWindowSimulator.measuredWindowSeconds.min()!,
            "撮影日時が最短の窓より短くなった＝模型の存在理由（並びのテストの死角）が消えた")

        // (d) 「決めてログを出すだけ」の手は窓を塞がないこと（`Kind` で丸めると塞ぐ）。
        XCTAssertEqual(NightlyWindowSimulator.seconds(for: .deferGenerate(streak: 1),
                                                      remaining: 10_000), 0,
                       "生成の見送りが窓を食っている＝`Kind` で丸めている（ADR-163 の常態を誤る）")

        // (e) ⚠️⚠️ **上限なしの手は窓の残りを食い切ること**。
        //     これを 1 秒に変えても 2 周目のレビューまで**全部 green** だった——
        //     「上限なしの後ろは順番が回らない」は `order` が存在する理由そのものなのに、
        //     今まで**どこにも assert が無かった**。しかも歯のある上限つき（撮影日時 40 秒）は
        //     2 か月で消える見込みなので、そのとき模型は識別力 0 で静かに緑になる。
        XCTAssertEqual(NightlyWindowSimulator.seconds(for: .shareSync, remaining: 123), 123,
                       "上限なしの手が窓の残りを食わない＝上限なしの後ろの飢餓を一切検出できない")
    }

    /// ⚠️⚠️ **必要な集合は「宣言」から導くこと。「計画」から引かないこと。**
    ///
    /// `required.insert(kind)` を `if planned.contains(kind)` で囲む（＝1 周目に壊れていた形に
    /// 戻す）変異は、2 周目のレビューまで**全部 green** だった。つまり追補 2 の直しの
    /// **肝心の性質にテストが無かった**——将来の「単純化」で穴がそのまま戻る。
    /// ⚠️ 空の計画に対して全部要求されること、が一番短い検査になる。
    func testTheRequiredSetComesFromDeclarationsNotFromThePlan() {
        XCTAssertEqual(NightlyPlan.requiredEveryWindowKinds(in: [], networkAllowed: true),
                       [.analysis, .stallCheck, .indexSnapshot, .backup], """
            必要な集合が**計画から**引かれている＝計画から落ちた手が飢餓に数えられない
            （ADR-266 / ADR-273 #3 の死角がそのまま戻る・ADR-274 追補 2 の穴 2）。
            """)
    }

    /// ⚠️ **回線で落とす毎窓の手を、飢餓に数えないこと。**
    ///
    /// ⚠️⚠️ `if !networkAllowed, s.dropWhenOffline { continue }` を no-op にしても**全部 green**
    /// だった——いま毎窓と宣言した 4 手はどれも `dropWhenOffline: false` なので、
    /// この分岐は**死んでいた**。`testOfflineWindows…` も
    /// 「回線で落ちた手を数えない」ではなく「回線に依る毎窓の手が無い」で通っていた
    /// （名前が持っていない網羅を主張していた）。偽りの seam で本物の材料を作る。
    func testNetworkGatedEveryWindowStepsAreNotCountedAsStarvedOffline() {
        NightlyWindowSimulator.withSpecOverride({ kind in
            guard kind == .captureDates else { return nil }
            return NightlyPlan.Spec(cost: .bounded, dropWhenOffline: true, everyWindow: true)
        }) {
            XCTAssertTrue(
                NightlyPlan.requiredEveryWindowKinds(in: [], networkAllowed: true)
                    .contains(.captureDates),
                "回線がある窓では要求されるはず")
            XCTAssertFalse(
                NightlyPlan.requiredEveryWindowKinds(in: [], networkAllowed: false)
                    .contains(.captureDates),
                "回線が無い窓で落とす毎窓の手を飢餓に数えている（誤報になる）")
        }
    }

    /// ⚠️ **窓が本当に打ち切っていること**を、打ち切りの位置で pin する。
    /// 以前の版は「`.unbounded` が残りを食う」ことしか示しておらず、
    /// 窓の長さを 100 万秒にしても通った（独立レビューの実測）。
    func testTheWindowActuallyTruncatesAtAKnownPoint() {
        var sim = simulator(provideShare: true, publishAnalysis: true)
        // analysis(0) → backup(0) → stallCheck(1) → indexSnapshot(1) → captureDates(40) …
        // 2 秒の窓なら、2 秒を使い切った `indexSnapshot` までで止まる。
        XCTAssertEqual(sim.runWindow(seconds: 2),
                       [.analysis, .backup, .stallCheck, .indexSnapshot],
                       "打ち切りの位置が変わった（ガード・時計・手の所要のどれかが壊れている）")

        let shortRan = sim.runWindow(seconds: 2)
        var long = simulator(provideShare: true, publishAnalysis: true)
        // ⚠️ 以前は `sim.windowsRun`（**窓の数**）と比べていた＝手の数と窓の数の比較で、
        //    しきい値が偶然 4 になっていた（独立レビューの指摘）。手の数どうしで比べる。
        XCTAssertGreaterThan(long.runWindow(seconds: 284).count, shortRan.count,
                             "長い窓の方が多くの手に順番が回るはず（模型が逆向き）")
    }

    /// ⚠️ `everyWindow` を宣言した手の**集合**を固定する。
    /// 以前は `count >= 4` だったので、**落ちない手（`analysis`）で数が埋まり**、
    /// 宣言漏れ（`publishAnalysis`）を隠せた（独立レビューの指摘）。
    func testTheEveryWindowDeclarationSetIsExact() {
        let declared = Set(NightlyPlan.Kind.allCases.filter { NightlyPlan.spec(for: $0).everyWindow })
        XCTAssertEqual(declared, [.analysis, .stallCheck, .indexSnapshot, .backup], """
            毎窓の宣言の集合が変わった。増やす/減らすときは根拠の ADR を宣言のコメントに書くこと。
            ⚠️ `captureDates` は throughput なので入れない（ADR-274 追補 2）。
            ⚠️ `publishAnalysis` は入れたい手だが、`after: [.shareImport]` が上限なしの後ろへ
               連れて行くので入れていない——実機で確かめる（device-verification 章 J-2）。
            """)
    }

    /// ⚠️⚠️ **免除が全構成で効いてしまう手は、宣言しても意味が無い**（空振りの免除）。
    ///
    /// 免除は `after` の相手が上限なしで同じ窓に居るかで導く。これは `backup` / `reconcile`
    /// には正しい（照合は**週 1** なので、免除されない窓が 51 回ある）。
    /// ⚠️ だが `after` の相手が**毎窓居る**手では、免除が**永久**になる——
    /// `publishAnalysis` を毎窓と宣言しても `shareImport`（毎窓・上限なし）が常に免除するので、
    /// 飢餓の掃きは**一度も落ちない**。それは ADR-222 追補が実機で踏んだ欠陥そのものなので、
    /// 「どこか 1 つの構成では免除されずに要求される」ことを固定する。
    func testNoEveryWindowStepIsExemptInEveryConfiguration() {
        let declared = NightlyPlan.Kind.allCases.filter { NightlyPlan.spec(for: $0).everyWindow }
        XCTAssertFalse(declared.isEmpty, "毎窓の宣言が 1 つも無い＝飢餓の assert が空振りする")

        for kind in declared {
            let requiredSomewhere = Self.axes.contains { axis in
                let sim = simulator(captureDateBacklog: axis.backlog, embedBacklog: axis.embed,
                                    provideShare: axis.share, publishAnalysis: axis.publish,
                                    boostActive: axis.boost)
                return NightlyWindowSimulator.requiredEveryWindowSteps(
                    in: sim.plan(reconcileDue: axis.reconcile), networkAllowed: true).contains(kind)
            }
            XCTAssertTrue(requiredSomewhere, """
                `\(kind)` は毎窓と宣言されているが、**どの構成でも免除される**
                ＝飢餓の assert が一度も効かない（宣言が ✅ の顔で居座る・ADR-253）。
                ⚠️ 原因はたいてい「`after` の相手が毎窓居る上限なしの手」。
                その場合、毎窓にしたいなら `after` を外すか、相手を上限つきにする必要がある
                ——宣言だけ足しても何も守られない（`publishAnalysis` で実証）。
                """)
        }
    }

    /// ⚠️⚠️ **上限つきなのに上限なしの後ろに居る手**を集合で固定する（並びの不変量・時間に依らない）。
    ///
    /// `order` は性質で並べるが、`after` は**性質より強い**。だから `after` 1 つで
    /// 上限つきの手が窓を食う手の後ろへ回り得る——ADR-222 追補が実機で踏んだ形そのもの。
    /// 現在そうなっているのは `publishAnalysis` **だけ**。増えたらここで落ちる。
    func testOnlyKnownBoundedStepsSitBehindAnUnboundedStep() {
        var found: Set<NightlyPlan.Kind> = []
        var checked = 0
        for axis in Self.axes {
            let sim = simulator(captureDateBacklog: axis.backlog, embedBacklog: axis.embed,
                                provideShare: axis.share, publishAnalysis: axis.publish,
                                boostActive: axis.boost)
            let plan = sim.plan(reconcileDue: axis.reconcile)
            var sawUnbounded = false
            for step in plan {
                let spec = NightlyPlan.spec(for: step.kind)
                guard spec.phase == .work else { continue }
                if spec.cost == .unbounded { sawUnbounded = true }
                else if spec.cost == .bounded, sawUnbounded { found.insert(step.kind) }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30, "構成を掃けていない＝空振り")
        XCTAssertEqual(found, [.publishAnalysis], """
            上限つきの手が上限なしの後ろに居る集合が変わった: \(found)
            ⚠️ `after` は性質より強いので、`after` を足すと静かにこうなる（ADR-222 追補の形）。
            増やすなら、その手が飢えてよい理由を宣言のコメントに書くこと。
            """)
    }

    // MARK: - 4. 過去の欠陥を捕まえられること（恒久シナリオ）

    /// ⚠️⚠️ **ADR-273 の忠実な再現**: `backup` を `.unbounded` と宣言すると、
    /// 導出が `backup` を上限なしの束（撮影日時 40 秒の**後ろ**）へ移し、
    /// 21 秒の窓では**その晩 1 枚も進まない**。
    ///
    /// ⚠️ 以前の版は偽りが `order` に届かず、並びが変わらないまま
    /// 「早く置かれた手が後ろを飢えさせた」という**別の仕組み**で通っていた。
    /// だから **`backup` が飢えたこと**を名指しで assert する（`isEmpty` では見分けられない）。
    func testTheSimulatorStarvesBackupWhenItIsMisdeclaredAsUnbounded() {
        NightlyWindowSimulator.withCostOverride(.unbounded, for: .backup) {
            var sim = self.simulator(provideShare: true, publishAnalysis: true)
            // 偽りが**並びに届いている**ことを先に確かめる（届かない版では変わらなかった）。
            let order = sim.plan().map(\.kind)
            XCTAssertGreaterThan(order.firstIndex(of: .backup)!, order.firstIndex(of: .captureDates)!,
                                 "偽りが `order` に届いていない（`backup` が前のまま）")

            sim.runWindow(seconds: 21)
            XCTAssertEqual(sim.starvedEveryWindowSteps(), [.backup],
                           "飢えたのが `backup` ではない＝模型が ADR-273 を見ていない")
            XCTAssertEqual(sim.world.executed[.backup, default: 0], 0, "回数でも 0 であること")
        }
    }

    /// ⚠️ **ADR-270 の忠実な再現**: 控えの書き直しが「窓を食う手の後ろ」に居た。
    ///
    /// 導出方式（ADR-272）では位置を手で指定できないので、**当時の並びをデータとして与える**。
    /// ⚠️ 置き先は `captureDates` の後ろ——上限つき同士なので
    /// `NightlyPlanOrderingTests` の `windowEating` には引っかからない（＝模型だけが見る穴）。
    func testTheSimulatorStarvesTheSnapshotRefreshWhenItIsOrderedAfterALongBoundedStep() throws {
        var sim = simulator(provideShare: true, publishAnalysis: true)
        let production = sim.plan()
        let buggy = try XCTUnwrap(Self.moving(.indexSnapshot, toAfter: .captureDates, in: production))
        XCTAssertNotEqual(buggy.map(\.kind), production.map(\.kind),
                          "並びを動かせていない＝シナリオが空振り")

        sim.runWindow(plan: buggy, seconds: 21)
        XCTAssertEqual(sim.starvedEveryWindowSteps(), [.indexSnapshot],
                       "飢えたのが控えの書き直しではない＝模型が ADR-270 を見ていない")
        XCTAssertEqual(sim.world.executed[.indexSnapshot, default: 0], 0, "回数でも 0 であること")
    }

    /// ⚠️⚠️ **この模型の限界を、限界として固定する。**
    ///
    /// ADR-273 の再現が効くのは「窓を使い切るほど長い**上限つき**の手が同じ窓に並ぶとき」だけ。
    /// 撮影日時の残りが 0 になれば（ADR-257 は 2 か月で一巡する見込み）**同じ偽りを見逃す**。
    /// ⚠️ 「見逃す」ことを assert するのは変だが、こう書かないと
    /// 「覆われている」と誤解されたまま、ある日静かに歯が無くなる（ADR-253）。
    func testTheBackupMisdeclarationIsInvisibleOnceNoLongBoundedStepIsPlanned() {
        NightlyWindowSimulator.withCostOverride(.unbounded, for: .backup) {
            var sim = self.simulator(captureDateBacklog: 0, provideShare: true, publishAnalysis: true)
            sim.runWindow(seconds: 21)
            XCTAssertTrue(sim.starvedEveryWindowSteps().isEmpty, """
                撮影日時の残りが 0 の窓で ADR-273 の偽りが**見えた**。
                限界が変わったのは良いことなので、この assert を消してヘッダの限界も直すこと。
                """)
        }
    }

    /// ⚠️ 偽りが**元に戻る**こと（スコープを抜けたら本番の宣言）。
    func testSpecOverrideIsScoped() {
        let real = NightlyPlan.spec(for: .backup).cost
        NightlyWindowSimulator.withCostOverride(.unbounded, for: .backup) {
            XCTAssertEqual(NightlyPlan.spec(for: .backup).cost, .unbounded)
        }
        XCTAssertEqual(NightlyPlan.spec(for: .backup).cost, real,
                       "スコープを抜けても偽りが残っている")
    }

    // MARK: - 5. 宣言が実態より小さいとどうなるか（限界 1 の測定）

    /// ⚠️⚠️ **1 手目が窓を食う世界**を測る（限界 1 を数にする）。
    ///
    /// `.analysis` は `.nonblocking` と宣言しているが、本番は `await kick(.window)` で
    /// 8.5 万件の列挙を待つ（実測 11〜38 秒）。模型は宣言を信じるので既定では見えない。
    /// ここで実測値を入れて**何が起きるかを予測**し、実機の確認に渡す
    /// （`device-verification.md` 章 J-3）。
    func testWhatHappensIfTheFirstStepEatsTheWindow() {
        var short = simulator(provideShare: true, publishAnalysis: true)
        short.analysisKickSeconds = 38          // `candidates.cloudRefs` の実測最悪値
        short.runWindow(seconds: 21)
        XCTAssertEqual(short.starvedEveryWindowSteps(), [.stallCheck, .indexSnapshot, .backup], """
            1 手目が 38 秒かかると、21 秒の窓では**毎窓の手が全部飢える**という予測。
            ⚠️ これは模型の既定では見えない（宣言が `.nonblocking` だから）。
            実機で `bgtask:` の行と `candidates.cloudRefs` の所要を突き合わせる（章 J-3）。
            """)

        var long = simulator(provideShare: true, publishAnalysis: true)
        long.analysisKickSeconds = 38
        long.runWindow(seconds: 57)
        XCTAssertTrue(long.starvedEveryWindowSteps().isEmpty,
                      "57 秒の窓なら 38 秒の 1 手目でも間に合う（飢餓は短い窓だけの話）")
    }

    // MARK: - 補助

    /// `kind` の手を `target` の直後へ動かした並びを返す（動かせなければ nil）。
    /// ⚠️ nil を返すのは**シナリオが成立していない**とき。呼び側は `XCTUnwrap` で止める
    /// （黙って元の並びを返すと、退行シナリオが空振りする）。
    private static func moving(_ kind: NightlyPlan.Kind, toAfter target: NightlyPlan.Kind,
                              in plan: [NightlyPlan.Step]) -> [NightlyPlan.Step]? {
        guard let moved = plan.first(where: { $0.kind == kind }), plan.contains(where: { $0.kind == target })
        else { return nil }
        var out = plan.filter { $0.kind != kind }
        guard let at = out.firstIndex(where: { $0.kind == target }) else { return nil }
        out.insert(moved, at: at + 1)
        return out
    }
}
