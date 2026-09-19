import Foundation
import Testing
@testable import MosaicSupport

/// 重い処理のゲート表（ADR-196）の判定。
///
/// 旧実装は 11 の述語（`heavyWorkAllowed` / `heavyWorkAllowedLocal` / `heavyShouldPause` …）が
/// 条件の**部分集合**を持ち、どれを使うかが呼び手の知識だった。ここでは表そのものを検証する。
@Suite("重い処理のゲート表（ADR-196）")
struct BackgroundGateTests {

    typealias Env = BackgroundYield.Environment
    typealias Work = BackgroundYield.HeavyWork
    typealias Blocker = BackgroundYield.Blocker

    /// 何も止めていない環境（背面・充電中・Wi-Fi・自動処理オン）。
    private func clean() -> Env { Env() }

    private func blockers(_ env: Env, _ work: Work,
                          _ ex: BackgroundYield.Exemption = .none) -> [Blocker] {
        BackgroundYield.blockers(env, for: work, exemption: ex)
    }

    // MARK: - 仕事ごとに課す条件が違う

    @Test("既定の環境（背面・充電中・Wi-Fi）はどの仕事も通る")
    func cleanEnvironmentAllowsEverything() {
        for work in Work.allCases {
            #expect(blockers(clean(), work).isEmpty, "\(work) が止まっている")
        }
    }

    @Test("回線を要求するのはクラウド分と一枚岩だけ（端末内写真は Wi-Fi 無しでも進む）")
    func networkOnlyAppliesToCloudWork() {
        var env = clean(); env.networkAllowed = false
        #expect(blockers(env, .localTrickle).isEmpty)
        #expect(blockers(env, .cloudTrickle) == [.networkBlocked])
        #expect(blockers(env, .cloudMonolith) == [.networkBlocked], "生成はクラウド一覧を読む")
        #expect(blockers(env, .localMonolith).isEmpty,
                "本番化・ドリフト再評価は台帳と埋め込みを読むだけ＝Wi-Fi 待ちで止めない")
        #expect(blockers(env, .window).isEmpty, "処理枠は回線を要求しない")
    }

    @Test("「App のバックグラウンド更新」が効くのは処理枠だけ（前面の解析は動く）")
    func backgroundRefreshOnlyAppliesToWindow() {
        var env = clean(); env.backgroundRefreshAvailable = false
        #expect(blockers(env, .window) == [.backgroundRefreshOff])
        #expect(blockers(env, .localTrickle).isEmpty)
        #expect(blockers(env, .cloudTrickle).isEmpty)
    }

    @Test("前面アクティブを拒むのは一枚岩だけ（ADR-107・トリクルは 1 単位ごとに譲れる）")
    func onlyMonolithRefusesForegroundActive() {
        var env = clean(); env.scenePhase = .active; env.idleSeconds = 999
        #expect(blockers(env, .localTrickle).isEmpty, "20 秒放置した前面ではトリクルは動く（ADR-195）")
        for work in [Work.localMonolith, .cloudMonolith] {
            #expect(blockers(env, work) == [.appActive],
                    "一枚岩が前面で動くと、戻ってきた利用者の操作が固まる（diagnostics-46）")
        }
    }

    /// 昨夜の退行（ADR-195 で「控えめ」軸を外したら `refinePlaceNames` → `generate` が
    /// 前面から到達可能になった）の回帰。**一枚岩は他が全部揃っていても前面では通らない**。
    @Test("回帰: 充電・Wi-Fi・20 秒放置がすべて揃っていても、前面では一枚岩は通らない")
    func monolithNeverRunsInForegroundEvenWhenEverythingElseIsFine() {
        var env = clean()
        env.scenePhase = .active
        env.idleSeconds = 3_600
        env.onPower = true
        env.networkAllowed = true
        #expect(blockers(env, .cloudMonolith).contains(.appActive))
        #expect(blockers(env, .cloudMonolith, .boost).contains(.boostRunning),
                "ブースト中は一枚岩を起こさない（始まると解析が止まる）")
    }

    // MARK: - 前面の扱い（ADR-195）

    @Test("前面で 20 秒触っていなければ動く・触っていれば止まる")
    func foregroundNeedsTwentySecondsIdle() {
        var env = clean(); env.scenePhase = .active
        env.idleSeconds = HeavyWorkTiming.foregroundIdleSeconds - 1
        #expect(blockers(env, .localTrickle) == [.foregroundNotIdle])
        env.idleSeconds = HeavyWorkTiming.foregroundIdleSeconds
        #expect(blockers(env, .localTrickle).isEmpty)
    }

    /// diagnostics-81 の回帰: 背面では「サムネ取得中」を理由に解析を止めない。
    /// 画面が無い時間帯に、バックアップ・共有・解析自身のサムネ取得で `uiBusy` が立ち続け、
    /// 夜間の CLIP 埋め込みが 1 枚も進まなかった。
    @Test("回帰: 背面では UI ビジーで止めない（窓を捨てない）")
    func backgroundIgnoresUIBusy() {
        var env = clean(); env.scenePhase = .background; env.uiBusy = true
        #expect(blockers(env, .localTrickle).isEmpty,
                "背面で「サムネ取得中」を理由に解析が止まっている（diagnostics-81）")
        env.scenePhase = .active; env.idleSeconds = 999
        #expect(blockers(env, .localTrickle) == [.uiBusy], "前面では従来どおり譲る")
    }

    @Test("メモリ圧迫は前面でも背面でも止める（jetsam の保護）")
    func memoryPressureAlwaysBlocks() {
        var env = clean(); env.memoryPressure = true
        #expect(blockers(env, .localTrickle) == [.memoryPressure])
        env.scenePhase = .active; env.idleSeconds = 999
        #expect(blockers(env, .localTrickle).contains(.memoryPressure))
    }

    // MARK: - 免除の段

    @Test("ブーストは方針の条件（自動処理オフ・電源・アイドル）を免除する")
    func boostSkipsPolicyConditions() {
        var env = clean()
        env.automaticEnabled = false
        env.powerPolicy = .whileCharging
        env.onPower = false
        env.scenePhase = .active
        env.idleSeconds = 0
        #expect(!blockers(env, .cloudTrickle).isEmpty, "平常なら止まる")
        #expect(blockers(env, .cloudTrickle, .boost).isEmpty, "ブーストは方針の条件を免除する")
    }

    /// ⚠️ **回線だけは例外**（レビュー指摘）。ADR-196 では「全力で解析」の一部として
    /// 免除したが、これは**利用者の実費**（68k 件のサムネをセルラーで取得し得る）。
    /// 「Wi-Fi のみ」は費用のために選ばれている設定なので、明示操作でも外さない。
    /// クラウド分を飛ばしたことは `.blocked([.networkBlocked])` で正直に報告する。
    @Test("回帰: 回線ポリシーはブーストでも外さない（通信費は利用者の実費）")
    func boostDoesNotOverrideTheDataPolicy() {
        var env = clean(); env.networkAllowed = false
        #expect(blockers(env, .cloudTrickle, .boost) == [.networkBlocked])
        #expect(blockers(env, .localTrickle, .boost).isEmpty, "端末内写真は通信不要なので進む")
        #expect(blockers(env, .cloudTrickle, .debug).isEmpty, "検証用のデバッグ全開だけは外せる")
    }

    @Test("熱・メモリ・一括ロードは誰も素通りできない（安全弁）")
    func safetyValvesAreNeverSkippable() {
        for (blocker, apply) in [(Blocker.tooHot, { (e: inout Env) in e.tooHot = true }),
                                 (Blocker.memoryPressure, { e in e.memoryPressure = true }),
                                 (Blocker.heavyLoad, { e in e.heavyLoadInFlight = true })] {
            var env = clean(); apply(&env)
            for ex in [BackgroundYield.Exemption.none, .boost, .debug] {
                #expect(blockers(env, .localTrickle, ex) == [blocker],
                        "\(blocker) が \(ex) で外れている")
            }
        }
    }

    /// レビュー指摘: 「電池のため止めた」と言った直後に方針が同じ処理を再開していた
    /// （電源ポリシー「常に」だと `backgroundAllowed()` が無条件に真で、電池の下限は
    /// ブーストのループの中にしか無かった）。電池は表の行にして、誰も外せないようにする。
    @Test("回帰: 電池の下限はブーストでも外れない（止めた直後に再開しない）")
    func lowBatteryBlocksEvenUnderBoost() {
        var env = clean()
        env.powerPolicy = .always          // 電源ポリシーは通す
        env.onPower = false
        env.batteryLevel = 0.19
        #expect(blockers(env, .localTrickle) == [.lowBattery])
        #expect(blockers(env, .localTrickle, .boost) == [.lowBattery])
        #expect(blockers(env, .localTrickle, .debug) == [.lowBattery])
        env.batteryLevel = 0.20
        #expect(blockers(env, .localTrickle).isEmpty, "下限ちょうどは止めない")
        env.batteryLevel = nil
        #expect(blockers(env, .localTrickle).isEmpty, "残量が読めないときは止めない")
        env.batteryLevel = 0.05; env.onPower = true
        #expect(blockers(env, .localTrickle).isEmpty, "充電中は止めない")
    }

    @Test("生成中と UI ビジーはブーストでも譲る（デバッグ全開だけが外せる）")
    func generatingAndUIBusyYieldEvenUnderBoost() {
        var env = clean(); env.generatingAlbums = true
        #expect(blockers(env, .localTrickle, .boost) == [.generating])
        #expect(blockers(env, .localTrickle, .debug).isEmpty)
    }

    @Test("電源ポリシー: 充電中のみ / 常に / オフ")
    func powerPolicyRows() {
        var env = clean(); env.onPower = false
        env.powerPolicy = .whileCharging
        #expect(blockers(env, .localTrickle) == [.notCharging])
        env.powerPolicy = .always
        #expect(blockers(env, .localTrickle).isEmpty)
        env.powerPolicy = .off
        #expect(blockers(env, .localTrickle) == [.powerOff],
                "以前は「オフ」を選んでいても画面に理由が出なかった")
    }

    // MARK: - 不変条件

    /// 旧実装の最大の欠陥: 入口（`heavyWorkAllowedLocal`）が譲り（`heavyShouldPause`）より
    /// **緩く**、一括ロード中・生成中に「入ってよい」と言われて 75,000 行を読んでから
    /// 譲り待ちに入り、60 秒で 0 枚のまま畳んでいた（diagnostics-62/63）。
    /// いまは同じ関数なので、どんな環境でも入口と譲りは一致する。
    @Test("不変条件: 入口と譲りは常に同じ答えになる")
    func entryAndYieldNeverDisagree() {
        // 条件を総当たりで組み合わせる（2^6 × 3 段 × 4 仕事）。
        for bits in 0..<64 {
            var env = clean()
            env.heavyLoadInFlight = bits & 1 != 0
            env.generatingAlbums  = bits & 2 != 0
            env.memoryPressure    = bits & 4 != 0
            env.onPower           = bits & 8 == 0
            env.networkAllowed    = bits & 16 == 0
            env.scenePhase        = bits & 32 != 0 ? .active : .background
            env.idleSeconds       = 999
            for ex in [BackgroundYield.Exemption.none, .boost, .debug] {
                for work in Work.allCases {
                    let entry = blockers(env, work, ex).isEmpty
                    let yields = !blockers(env, work, ex).isEmpty
                    #expect(entry != yields, "入口と譲りが食い違う（\(work)/\(ex)/bits=\(bits)）")
                }
            }
        }
    }

    @Test("止めている条件は「直しやすい順」に並ぶ（画面がこの順で出す）")
    func blockersAreOrderedByFixability() {
        var env = clean()
        env.automaticEnabled = false
        env.onPower = false
        env.tooHot = true
        let order = blockers(env, .cloudTrickle)
        #expect(order.first == .automaticOff, "アプリの設定が先頭（いちばん直しやすい）")
        #expect(order.last == .tooHot, "端末の状態は後ろ")
    }
}

/// ADR-197: ADR-195 で誤って廃止した「前面でも解析するか」の設定を、表の行として戻したもの。
///
/// 廃止の根拠は「トリクルは 1 単位ごとに譲るので体感の代償が無い」だったが、これは**応答性**に
/// しか答えていない——**電池と発熱**の代償は残る。「手に持って使っている間は一切動かして
/// ほしくない」という要求は正当なので、選べる形に戻した。
@Suite("前面で解析するかの設定（ADR-197）")
struct ForegroundAnalysisSettingTests {

    typealias Env = BackgroundYield.Environment
    typealias Blocker = BackgroundYield.Blocker

    private func blockers(_ env: Env, _ work: BackgroundYield.HeavyWork,
                          _ ex: BackgroundYield.Exemption = .none) -> [Blocker] {
        BackgroundYield.blockers(env, for: work, exemption: ex)
    }

    @Test("OFF なら前面では動かない（20 秒放置していても）")
    func offStopsForegroundWork() {
        var env = Env(foregroundAnalysisEnabled: false, idleSeconds: 999, scenePhase: .active)
        #expect(blockers(env, .localTrickle) == [.foregroundAnalysisOff])
        env.foregroundAnalysisEnabled = true
        #expect(blockers(env, .localTrickle).isEmpty, "ON なら従来どおり進む")
    }

    @Test("OFF でも背面（ロック中・他アプリ使用中）は動く＝夜間の解析は止まらない")
    func offDoesNotStopBackgroundWork() {
        let env = Env(foregroundAnalysisEnabled: false, scenePhase: .background)
        #expect(blockers(env, .localTrickle).isEmpty)
        #expect(blockers(env, .cloudTrickle).isEmpty)
        #expect(blockers(env, .window).isEmpty, "処理枠の予約にも影響しない")
    }

    @Test("OFF でも「今すぐ解析」は動く（明示操作は免除）")
    func boostIgnoresTheSetting() {
        let env = Env(foregroundAnalysisEnabled: false, idleSeconds: 0, scenePhase: .active)
        #expect(!blockers(env, .localTrickle).isEmpty)
        #expect(blockers(env, .localTrickle, .boost).isEmpty)
    }

    /// 画面は止めている条件を「直しやすい順」に出すので、並びは宣言順に揃っていること。
    @Test("止めている条件の並びは宣言順（アプリの設定が先頭）")
    func blockersKeepDeclaredOrder() {
        let env = Env(automaticEnabled: false, foregroundAnalysisEnabled: false,
                      tooHot: true, idleSeconds: 0, scenePhase: .active)
        let order = blockers(env, .localTrickle)
        #expect(order.first == .automaticOff)
        #expect(order.contains(.foregroundAnalysisOff))
        #expect(order.firstIndex(of: .foregroundAnalysisOff)! < order.firstIndex(of: .tooHot)!,
                "アプリの設定（直しやすい）は端末の状態より前")
    }
}
