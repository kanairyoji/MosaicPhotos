import MosaicSupport
import XCTest
@testable import MosaicPhotos

/// ブースト（「今すぐ解析」・ADR-182/195）の判断。
final class AnalysisSessionPolicyTests: XCTestCase {

    func testProgressNeverExceedsTotalAndWarmupCounts() {
        let p0 = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 100, warmupTicks: 0)
        XCTAssertEqual(p0.completed, 0)
        XCTAssertEqual(p0.total, 100 + AnalysisSessionPolicy.warmupUnits)
        let warm = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 100, warmupTicks: 5)
        XCTAssertEqual(warm.completed, 5, "準備中も進捗が進む（報告なしは OS に殺される）")
        let over = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 0, warmupTicks: 999)
        XCTAssertEqual(over.completed, over.total, "上限で頭打ち")
        let grew = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 150, warmupTicks: 0)
        XCTAssertEqual(grew.completed, 0, "残りが分母を超えても負にならない")
    }

    /// ⚠️ 「終わった」は残作業ゼロのことではない。ゲートで畳んだ場合と区別するのは
    /// 呼び出し側（`AnalysisSession.watchProgress` がゲートに理由を聞く）。
    func testFinishedMeansNothingIsRunnableRightNow() {
        XCTAssertTrue(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: false, scanning: false))
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: true, scanning: false))
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: false, scanning: true))
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 3, tagging: false, scanning: false))
    }

    /// ⚠️ **「いま動かせるものが無い」は「終わった」ではない**（ADR-207）。
    /// 以前は `blockers.isEmpty ? .finished : .blocked(blockers)` だけで、
    /// 理由の無い未完了を表す道が無かった。しかも画面側は `.blocked([])` を
    /// 「すべて解析済みです」に落としていたので、**2 重に嘘へ丸められていた**。
    func testStopReasonNeverClaimsDoneWhileFacesRemain() {
        XCTAssertEqual(AnalysisSessionPolicy.stopReason(blockers: [], faceBacklog: 0), .finished)
        XCTAssertEqual(AnalysisSessionPolicy.stopReason(blockers: [], faceBacklog: 7),
                       .incomplete(remaining: 7),
                       "顔が 7 枚残っているのに『すべて解析済み』と言っている")
        XCTAssertEqual(AnalysisSessionPolicy.stopReason(blockers: [.tooHot], faceBacklog: 0),
                       .blocked([.tooHot]),
                       "止めている理由があるなら、それを言う（残りが 0 でも）")
        XCTAssertEqual(AnalysisSessionPolicy.stopReason(blockers: [.tooHot], faceBacklog: 7),
                       .blocked([.tooHot]),
                       "理由があるときは理由を優先する（利用者が直せるのはこちら）")
    }

    func testRemainingClampsNegatives() {
        XCTAssertEqual(AnalysisSessionPolicy.remaining(faces: -1, tagsPending: 2, embedPending: -5), 2)
    }
}

/// 処理枠が「来ているか」の健全性（diagnostics-81）。
/// 条件そのものはゲート表（`BackgroundGateTests`）の担当で、ここは沈黙の検出だけ。
final class AnalysisWindowHealthTests: XCTestCase {

    func testStarvationOnlyCountsWhenNothingElseBlocks() {
        XCTAssertTrue(AnalysisWindowHealth.isStarved(blockers: [], minutesSinceLastWindow: 13 * 60))
        XCTAssertFalse(AnalysisWindowHealth.isStarved(blockers: [], minutesSinceLastWindow: 60),
                       "数時間の空白は正常（OS の裁量）")
        XCTAssertFalse(AnalysisWindowHealth.isStarved(blockers: [.notCharging],
                                                      minutesSinceLastWindow: 24 * 60),
                       "理由が分かっているときは「枠が来ない」と言わない")
        XCTAssertFalse(AnalysisWindowHealth.isStarved(blockers: [], minutesSinceLastWindow: nil),
                       "一度も開いていない端末では判断しない")
    }
}

/// ADR-195/196: 常設の方針を評価して残作業を進める駆動役の判断。
/// 「再開」は無い——条件が揃っていれば起こし、揃っていなければ何もしない、だけ。
@MainActor
final class AnalysisDriverPolicyTests: XCTestCase {

    private func decide(_ trigger: AnalysisDriver.Trigger,
                        phase: BackgroundYield.ScenePhaseKind = .active,
                        blockers: [BackgroundYield.Blocker] = [],
                        boost: Bool = false, running: Bool = false,
                        since: TimeInterval = 9_999, empty: Int = 0) -> AnalysisDriverPolicy.Decision {
        AnalysisDriverPolicy.decide(
            trigger: trigger, scenePhase: phase,
            verdict: .init(work: .localTrickle, blockers: blockers),
            boostActive: boost, workRunning: running,
            sinceLastKick: since, emptyStreak: empty)
    }

    func testKicksWhenTheGateIsOpenInForeground() {
        XCTAssertEqual(decide(.foreground), .kick)
        XCTAssertEqual(decide(.power), .kick)
        XCTAssertEqual(decide(.idle), .kick)
        XCTAssertEqual(decide(.launch), .kick)
    }

    func testBackgroundIsLeftToTheProcessingWindow() {
        XCTAssertEqual(decide(.power, phase: .background), .background, "背面は処理枠の管轄")
    }

    /// ADR-95: 窓は特権時間なので、滞留した前面の実行を明け渡させてから始め直す。
    /// ここで「走行中だから何もしない」と判断すると、窓が丸ごと空転する（diagnostics-38）。
    func testTheWindowAlwaysKicksEvenWhileWorkIsRunning() {
        XCTAssertEqual(decide(.window, phase: .background, running: true), .kick)
        XCTAssertEqual(decide(.window, phase: .background, blockers: [.notCharging]), .kick,
                       "窓の中のゲート判定は各トリクルが 1 単位ごとに見る")
    }

    func testDoesNotStackOnTopOfABoost() {
        XCTAssertEqual(decide(.idle, boost: true), .boostActive)
        XCTAssertEqual(decide(.boost, boost: true), .kick, "ブーストの開始だけは通す")
    }

    func testRespectsTheGate() {
        XCTAssertEqual(decide(.foreground, blockers: [.notCharging]), .notAllowed)
        XCTAssertEqual(decide(.foreground, blockers: [.foregroundNotIdle]), .notAllowed)
    }

    /// レビュー指摘: 起こすたびに 86k 件と 75k 件を読む前口上が走っていた。
    /// すでに走っているなら**入口の代金を払わない**。
    func testDoesNothingWhileWorkIsAlreadyRunning() {
        XCTAssertEqual(decide(.idle, running: true), .alreadyRunning)
        XCTAssertEqual(decide(.power, running: true), .alreadyRunning)
    }

    func testIdleTriggerIsThrottledButConditionChangesAreNot() {
        XCTAssertEqual(decide(.idle, since: 10), .throttled, "5 秒ごとの検知をそのまま毎回起こさない")
        XCTAssertEqual(decide(.idle, since: AnalysisDriverPolicy.idleKickInterval), .kick)
        XCTAssertEqual(decide(.power, since: 0), .kick, "条件の変化は即座に反映する")
        XCTAssertEqual(decide(.network, since: 0), .kick)
        XCTAssertEqual(decide(.boostEnded, since: 0), .kick)
    }

    /// レビュー指摘: 残作業が無いのに 5 秒ごとの検知へ素直に従うと、充電しながらアプリを
    /// 開いているだけで 1 時間に数十回、全ライブラリを読み直す。
    func testEmptyKicksBackOff() {
        XCTAssertEqual(AnalysisDriverPolicy.idleInterval(emptyStreak: 0), 60)
        XCTAssertTrue(AnalysisDriverPolicy.idleInterval(emptyStreak: 1) > AnalysisDriverPolicy.idleInterval(emptyStreak: 0))
        XCTAssertTrue(AnalysisDriverPolicy.idleInterval(emptyStreak: 4) >= 1800, "上限は 30 分")
        // 空振りが続くほど間引かれる（同じ経過秒でも判断が変わる）。
        XCTAssertEqual(decide(.idle, since: 90, empty: 0), .kick)
        XCTAssertEqual(decide(.idle, since: 90, empty: 1), .throttled)
        // ただし条件が変わった契機は、空振りが続いていても間引かない。
        XCTAssertEqual(decide(.power, since: 0, empty: 9), .kick)
    }
}

/// ADR-196: 処理枠で「何を・どの順でやるか」。
/// 以前は `HeavyWorkScheduler.runHeavyWork`（142 行）に直書きで、**テストが 1 本も無かった**。
final class NightlyPlanTests: XCTestCase {

    private func labels(_ i: NightlyPlan.Inputs) -> [String] { NightlyPlan.steps(i).map(\.label) }

    /// 順序は実機の失敗が出典（Fix C・ADR-180・diagnostics-72）。**動かすならここを見る**。
    func testDefaultOrderIsAnalysisThenBackupThenGenerate() {
        let steps = labels(.init())
        // 既定の `Inputs` は回線あり・照合の期限は来ていない。共有はその中に並ぶ。
        XCTAssertEqual(steps, ["analysis", "stallCheck", "backup", "generate",
                               "shareImport", "drain"])
        XCTAssertTrue(steps.firstIndex(of: "analysis")! < steps.firstIndex(of: "generate")!,
                      "generate を先に await すると窓を食い潰して顔/埋め込みが開始すらしない（Fix C）")
        XCTAssertTrue(steps.firstIndex(of: "backup")! < steps.firstIndex(of: "generate")!,
                      "バックアップは解析と並行・毎窓（ADR-180）")
    }

    func testBoostSuppressesAnalysisButNotTheRest() {
        let steps = labels(.init(boostActive: true))
        XCTAssertEqual(steps.first, "analysis(skip:boost)", "同じトリクルを重ねて起こさない")
        XCTAssertTrue(steps.contains("backup"))
    }

    /// diagnostics-72: 同じ窓で生成と解析を走らせると、生成が `isGeneratingAlbums` を立てて
    /// 解析が止まり、生成自体も 26 秒では終わらず、窓が丸ごと空転する。
    func testGenerateIsDeferredWhileAnalysisHasBacklog() {
        XCTAssertTrue(labels(.init(embedBacklog: 100)).contains("generate(defer:1)"))
        XCTAssertTrue(labels(.init(faceBacklog: 5)).contains("generate(defer:1)"))
        XCTAssertTrue(labels(.init(embedBacklog: 100, generateDeferrals: 2)).contains("generate(defer:3)"))
    }

    /// ADR-163: ただし生成も飢えさせない（上限を超えたら窓を明け渡す）。
    func testGenerateGetsItsTurnAfterTheDeferralLimit() {
        let steps = labels(.init(embedBacklog: 100, generateDeferrals: 4, maxGenerateDeferrals: 4))
        XCTAssertTrue(steps.contains("generate"), "見送り上限を超えたら生成の順番")
    }

    /// generate はピークが 550〜880MB で、BG の jetsam 上限に触れるとアプリごと kill される。
    func testGenerateIsSkippedWhenMemoryIsTight() {
        let steps = labels(.init(availableMB: NightlyPlan.minimumGenerateMB))
        XCTAssertTrue(steps.contains("generate(skip:\(NightlyPlan.minimumGenerateMB)MB)"))
        XCTAssertFalse(steps.contains("generate"))
    }

    func testShareStepsFollowTheNetworkAndProvideSettings() {
        XCTAssertFalse(labels(.init(networkAllowed: false)).contains("shareImport"))
        XCTAssertFalse(labels(.init()).contains("shareSync"), "提供がオフなら反映しない")
        XCTAssertTrue(labels(.init(provideShareEnabled: true)).contains("shareSync"))
    }

    /// ADR-222: 解析の公開も回線の中。設定がオフなら 1 バイトも上げない。
    func testPublishAnalysisFollowsTheNetworkAndItsSetting() {
        XCTAssertFalse(labels(.init()).contains("publishAnalysis"), "設定がオフなら公開しない")
        XCTAssertFalse(labels(.init(networkAllowed: false, publishAnalysisEnabled: true))
                        .contains("publishAnalysis"),
                       "回線が許されないのにアップロードしている（Wi-Fi のみでもセルラーで走る）")
        let steps = labels(.init(provideShareEnabled: true, publishAnalysisEnabled: true))
        guard let publish = steps.firstIndex(of: "publishAnalysis"),
              let importStep = steps.firstIndex(of: "shareImport"),
              let sync = steps.firstIndex(of: "shareSync") else {
            return XCTFail("公開の手が無い: \(steps)")
        }
        XCTAssertTrue(importStep < publish, """
            公開が取り込みより先にある（\(steps)）。受け取った解析が自分の台帳に入る前に
            公開すると、同じ写真を 2 人が別々に解析し直す空回りが止まらない。
            """)
        // 回帰: 実機ログ diagnostics-83 では、最後に置いた公開に**一度も順番が回らなかった**。
        // 反映は 1 回 500 件ずつコピーし、残り 9,265 件で窓（5 分）を使い切る。
        XCTAssertTrue(publish < sync, """
            公開が共有セットの反映より後にある（\(steps)）。反映は窓を使い切るので、
            上限つきで軽い公開は先に出すこと。
            """)
    }

    /// 回帰: **週次の照合も回線ポリシーに従う**（レビュー 11 周目）。
    /// Dropbox の全件一覧を引く手なのに、以前は回線の判定の外にあり、
    /// 「Wi-Fi のみ」でもセルラーで引き得た（利用者の実費・ADR-198 と同じ問題）。
    func testWeeklyReconcileRequiresTheNetwork() {
        XCTAssertFalse(labels(.init(networkAllowed: false, backupReconcileDue: true)).contains("reconcile"),
                       "回線が許されないのに全件一覧を引く（Wi-Fi のみでもセルラーで走る）")
        XCTAssertTrue(labels(.init(networkAllowed: true, backupReconcileDue: true)).contains("reconcile"))
    }

    /// ⚠️ **照合はバックアップより前**（ADR-206）。`.startBackup` は投げっぱなしで
    /// `isRunning` を立て、照合は `guard !isBusy` で門前払いされる。ADR-180 で 1 回あたりの
    /// 上限を外してから、積み残しのある端末では窓いっぱい busy のままになり、
    /// **照合がいちばん要る端末で、照合だけが永久に走らなかった**。
    /// 照合はオフロードの緊急停止（ADR-202）の唯一の発火点なので、走らないと
    /// 「唯一のコピーが消えた」ことに誰も気づけない。
    func testDueReconcileRunsBeforeBackup() {
        let steps = labels(.init(backupReconcileDue: true))
        guard let reconcile = steps.firstIndex(of: "reconcile"),
              let backup = steps.firstIndex(of: "backup") else {
            return XCTFail("期限の週に照合の手が無い: \(steps)")
        }
        XCTAssertTrue(reconcile < backup, """
            照合がバックアップより後にある（\(steps)）。
            バックアップが isRunning を立てるので、照合は guard !isBusy で必ず空振りする。
            """)
    }

    /// ふだんの週は手順を変えない（52 回に 1 回だけ前へ出る）。
    func testReconcileIsAbsentWhenNotDue() {
        XCTAssertFalse(labels(.init(backupReconcileDue: false)).contains("reconcile"),
                       "期限が来ていないのに全件一覧を引いている")
    }

    /// 窓は必ず「待つ」で終わる（残作業が続く限り期限まで使い切る）。
    func testEveryPlanEndsByDraining() {
        for inputs in [NightlyPlan.Inputs(), .init(boostActive: true), .init(networkAllowed: false),
                       .init(embedBacklog: 10), .init(availableMB: 0)] {
            XCTAssertEqual(labels(inputs).last, "drain")
        }
    }
}

/// ADR-119 の規模テスト: 駆動役の前口上は**ライブラリ規模に比例する**（PHAsset の列挙＋
/// クラウド 68k 件の並べ替え＋`scannedRefKeys` 75k 行）。起こす回数を増やしても、
/// その回数に比例して列挙が増えないことを**回数で**固定する。
@MainActor
final class AnalysisDriverScaleTests: XCTestCase {

    /// 起こす契機を 4 倍にしても、間引きの判断（`.throttled` / `.alreadyRunning`）で
    /// 実際に前口上へ進む回数は比例して増えない。
    func testIdleTicksDoNotScaleIntoPrologues() {
        // アイドル監視は 5 秒ごとに来る。残作業が無い（空振り）状態で 20 分ぶん回す。
        func prologues(ticks: Int) -> Int {
            var last = Date.distantPast
            var empty = 0
            var count = 0
            let start = Date()
            for i in 0..<ticks {
                let now = start.addingTimeInterval(Double(i) * 5)
                let d = AnalysisDriverPolicy.decide(
                    trigger: .idle, scenePhase: .active,
                    verdict: .init(work: .localTrickle, blockers: []),
                    boostActive: false, workRunning: false,
                    sinceLastKick: now.timeIntervalSince(last), emptyStreak: empty)
                if d == .kick { count += 1; last = now; empty += 1 }   // 空振り＝残作業なし
            }
            return count
        }
        let base = prologues(ticks: 240)        // 20 分
        let quadrupled = prologues(ticks: 960)  // 80 分
        XCTAssertLessThanOrEqual(quadrupled, base + 3,
                                 "検知を 4 倍にしたら前口上も 4 倍走っている（バックオフが効いていない）")
        XCTAssertGreaterThan(base, 0, "そもそも 1 度も起こしていない（テストが何も守っていない）")
    }

    /// 走っている間は何度来ても前口上を払わない。
    func testNoPrologueWhileWorkIsRunning() {
        for i in 0..<100 {
            let d = AnalysisDriverPolicy.decide(
                trigger: .idle, scenePhase: .active,
                verdict: .init(work: .localTrickle, blockers: []),
                boostActive: false, workRunning: true,
                sinceLastKick: Double(i) * 60, emptyStreak: 0)
            XCTAssertEqual(d, .alreadyRunning)
        }
    }

    func testCandidateCacheWindow() {
        let now = Date()
        XCTAssertTrue(AnalysisDriverPolicy.canReuseCandidates(cachedAt: now, now: now))
        XCTAssertTrue(AnalysisDriverPolicy.canReuseCandidates(
            cachedAt: now.addingTimeInterval(-AnalysisDriverPolicy.candidateReuse + 1), now: now))
        XCTAssertFalse(AnalysisDriverPolicy.canReuseCandidates(
            cachedAt: now.addingTimeInterval(-AnalysisDriverPolicy.candidateReuse), now: now))
        XCTAssertFalse(AnalysisDriverPolicy.canReuseCandidates(
            cachedAt: now.addingTimeInterval(60), now: now), "時計が戻ったら使い回さない")
    }
}
