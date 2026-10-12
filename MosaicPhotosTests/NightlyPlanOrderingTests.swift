import XCTest
@testable import MosaicPhotos

/// **夜間の窓の「並び」を、入力の全組み合わせで固定する**（ADR-271）。
///
/// ⚠️⚠️ なぜ要るか（ADR-270 で踏んだ）
/// `NightlyPlan.steps` の順序の制約は**コメントにしか無く**、`out.append` の行はどれも
/// 同じ見た目になる。実際、同じ関数に 2 回書いてある制約
/// （「`shareSync` は窓を使い切る」「後ろに置いた手は一度も順番が回ってこない」）を
/// **自分で破った**——`.refreshCloudIndexSnapshot` を `shareSync` の後ろに置き、
/// 提供がオンの端末では ADR-266 が**何もしない**状態になっていた。
///
/// ⚠️⚠️ そして**既存のテストはそれを見られなかった**。理由は構造的で、
/// 順序の不変条件は「**両方の手が並んだときだけ**」意味を持つのに、
/// テストは手で選んだ構成しか作らないから。`Inputs.provideShareEnabled` の既定は `false` で、
/// 既定の構成には `shareSync` が入らない——**制約が一度も試されなかった**。
///
/// だから**入力の全組み合わせ**を作って、文書化されている制約を全部当てる。
/// 入力は真偽値 6 つ ＋ 生成の 3 状態＝192 通りで、総当たりでも一瞬で終わる。
///
/// ⚠️ **新しい手を足したら、ここに制約を 1 行足す**。足さないと「並びは自由」と宣言したことになる。
final class NightlyPlanOrderingTests: XCTestCase {

    // MARK: - 入力の全組み合わせ

    /// 生成がどの形で現れるか（入力の組み合わせで 3 通りに分かれる）。
    private enum GenerateShape: CaseIterable {
        /// 残作業なし → `generate`
        case runs
        /// 残作業あり・上限前 → `generate(defer:N)`
        case defers
        /// 空きメモリ不足 → `generate(skip:NMB)`
        case skipsLowMemory

        var apply: (inout NightlyPlan.Inputs) -> Void {
            switch self {
            case .runs:
                return { $0.embedBacklog = 0; $0.faceBacklog = 0; $0.availableMB = 2048 }
            case .defers:
                return { $0.embedBacklog = 100; $0.generateDeferrals = 0; $0.availableMB = 2048 }
            case .skipsLowMemory:
                return { $0.embedBacklog = 0; $0.faceBacklog = 0
                         $0.availableMB = NightlyPlan.minimumGenerateMB }
            }
        }
    }

    /// 192 通り（真偽値 6 つ × 生成 3 形）。
    private func allInputs() -> [(name: String, inputs: NightlyPlan.Inputs)] {
        var out: [(String, NightlyPlan.Inputs)] = []
        for boost in [false, true] {
            for network in [false, true] {
                for provide in [false, true] {
                    for publish in [false, true] {
                        for reconcile in [false, true] {
                            for captureDates in [false, true] {
                                for shape in GenerateShape.allCases {
                                    var i = NightlyPlan.Inputs(
                                        boostActive: boost,
                                        networkAllowed: network,
                                        provideShareEnabled: provide,
                                        backupReconcileDue: reconcile,
                                        publishAnalysisEnabled: publish,
                                        captureDateBacklog: captureDates ? 1_000 : 0)
                                    shape.apply(&i)
                                    let name = "boost=\(boost) net=\(network) provide=\(provide) "
                                        + "publish=\(publish) reconcile=\(reconcile) "
                                        + "captureDates=\(captureDates) generate=\(shape)"
                                    out.append((name, i))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    private func labels(_ i: NightlyPlan.Inputs) -> [String] {
        NightlyPlan.steps(i).map(\.label)
    }

    /// `prefix` で始まる手の位置（無ければ nil）。
    private func index(_ steps: [String], startingWith prefix: String) -> Int? {
        steps.firstIndex { $0.hasPrefix(prefix) }
    }

    // MARK: - 制約（文書化されているものを全部）

    /// ⚠️ **窓を塞ぐ手**＝`perform` が返るまで長い手。後ろに置いた手は順番が回ってこない。
    /// - `generate`: 550〜880MB・数十秒（`minimumGenerateMB` が在る理由）
    /// - `shareSync`: 実機でコピー待ち 9,265 件・1 回 500 件（ADR-222 追補）
    /// - `reconcile`: Dropbox の全件一覧（ADR-206）
    /// - `drain`: 期限まで待つ
    ///
    /// ⚠️⚠️ **`backup` は入らない**（独立レビューの指摘で直した）。
    /// `startBackup` は `backupEngine.startNightlyIfEnabled()` を呼ぶだけで**即座に返る**
    /// ——仕事は engine が裏で続ける。ADR-180 の「毎窓・上限なし」は**仕事**の話で、
    /// **手**は窓を塞がない。ここに入れていたので `backup` を `.unbounded` と宣言してしまい、
    /// 40 秒の撮影日時の問い合わせが前に出て、短い窓（実測 21 秒）では
    /// バックアップが**その晩まったく進まない**ところだった。
    /// **「仕事が長い」と「手が窓を塞ぐ」は別**。
    private static let windowEating = ["generate", "shareSync", "reconcile", "drain"]

    /// ⚠️⚠️ **ADR-270 で踏んだ制約**。控えの書き直しは軽く・回線も要らないので、
    /// 窓を使い切る手より**前**でなければ、提供オンの端末で一度も走らない。
    func testIndexSnapshotRefreshPrecedesEveryWindowEatingStepInEveryConfiguration() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            guard let snap = steps.firstIndex(of: "indexSnapshot") else {
                return XCTFail("控えの書き直しが手順に無い [\(name)]: \(steps)")
            }
            for prefix in Self.windowEating {
                guard let other = index(steps, startingWith: prefix) else { continue }
                XCTAssertLessThan(snap, other, """
                    控えの書き直しが「\(prefix)」より後ろにある＝一度も順番が回ってこない。
                    [\(name)]
                    \(steps)
                    """)
            }
        }
    }

    /// ⚠️ 控えの書き直しは**回線を要さない**（ローカルの書き出しだけ）。
    /// 全組み合わせで必ず 1 回だけ現れること。
    func testIndexSnapshotRefreshIsAlwaysPresentExactlyOnce() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            XCTAssertEqual(steps.filter { $0 == "indexSnapshot" }.count, 1,
                           "控えの書き直しが 1 回でない [\(name)]: \(steps)")
        }
    }

    /// ⚠️⚠️ **投げっぱなしの手は、塞ぐ手より前に出す**（独立レビューの指摘・ADR-272 追補）。
    ///
    /// `startBackup` は即座に返り、仕事は engine が裏で続ける（ADR-180「毎窓」）。
    /// だから**窓の最初のうちに蹴っておけば、他の手が走っている間ずっと進む**。
    /// 逆に塞ぐ手（40 秒の撮影日時の問い合わせなど）の後ろに置くと、
    /// 短い窓（実測 **21 秒**）では `Task.isCancelled` が先に立って**その晩 1 枚も進まない**。
    ///
    /// ⚠️ 照合の期限が来た週だけは例外（`after: [.reconcile]`）——`.startBackup` が
    /// `isRunning` を立てると照合が `guard !isBusy` で門前払いされるので、照合を先にやる
    /// （52 回に 1 回・ADR-206）。
    func testBackupIsKickedBeforeAnyBlockingStepWhenReconcileIsNotDue() {
        var checked = 0
        for (name, inputs) in allInputs() where !inputs.backupReconcileDue {
            let steps = labels(inputs)
            guard let backup = steps.firstIndex(of: "backup") else {
                return XCTFail("バックアップの手が無い [\(name)]: \(steps)")
            }
            for prefix in Self.windowEating where prefix != "reconcile" {
                guard let blocking = index(steps, startingWith: prefix) else { continue }
                checked += 1
                XCTAssertLessThan(backup, blocking, """
                    バックアップが「\(prefix)」より後ろ＝短い窓ではその晩 1 枚も進まない。
                    [\(name)] \(steps)
                    """)
            }
            // 上限つきの塞ぐ手（撮影日時の問い合わせ）より前であること。
            if let probe = index(steps, startingWith: "captureDates") {
                checked += 1
                XCTAssertLessThan(backup, probe, """
                    バックアップが撮影日時の問い合わせ（40 秒）より後ろ。
                    [\(name)] \(steps)
                    """)
            }
        }
        XCTAssertGreaterThan(checked, 0, "照合の期限が来ていない構成を 1 つも見ていない")
    }

    /// ⚠️ 照合の期限が来た週は、照合 → バックアップの順（資源の競合・ADR-206）。
    func testBackupFollowsReconcileWhenDue() {
        var checked = 0
        for (name, inputs) in allInputs() where inputs.backupReconcileDue && inputs.networkAllowed {
            let steps = labels(inputs)
            guard let reconcile = steps.firstIndex(of: "reconcile"),
                  let backup = steps.firstIndex(of: "backup") else { continue }
            checked += 1
            XCTAssertLessThan(reconcile, backup, "照合が後ろ [\(name)]: \(steps)")
        }
        XCTAssertGreaterThan(checked, 0, "照合の期限が来た構成を 1 つも見ていない")
    }

    /// ADR-222 追補: 公開は**取り込みの後・反映の前**。
    /// 「後」は受け取った解析が台帳に入ってから公開したいから。
    /// 「前」は反映が窓を使い切るから。
    func testPublishAnalysisSitsBetweenShareImportAndShareSync() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            guard let publish = steps.firstIndex(of: "publishAnalysis") else { continue }
            if let importStep = steps.firstIndex(of: "shareImport") {
                XCTAssertLessThan(importStep, publish,
                                  "公開が取り込みより前 [\(name)]: \(steps)")
            }
            if let sync = steps.firstIndex(of: "shareSync") {
                XCTAssertLessThan(publish, sync, "公開が反映より後ろ [\(name)]: \(steps)")
            }
        }
    }

    /// ADR-257: 撮影日時の問い合わせは**反映より前**（上限つきで軽い）。
    func testCaptureDateProbePrecedesShareSync() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            guard let probe = index(steps, startingWith: "captureDates"),
                  let sync = steps.firstIndex(of: "shareSync") else { continue }
            XCTAssertLessThan(probe, sync, "撮影日時が反映より後ろ [\(name)]: \(steps)")
        }
    }

    /// ADR-206: 照合は**バックアップより前**（後ろだと `guard !isBusy` で必ず空振りする）。
    func testBackupReconcilePrecedesBackup() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            guard let reconcile = steps.firstIndex(of: "reconcile"),
                  let backup = steps.firstIndex(of: "backup") else { continue }
            XCTAssertLessThan(reconcile, backup, "照合がバックアップより後ろ [\(name)]: \(steps)")
        }
    }

    /// Fix C: 解析は**最初**（generate を先に await すると窓を食い潰して開始すらしない）。
    func testAnalysisIsAlwaysFirst() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            XCTAssertTrue(steps.first == "analysis" || steps.first == "analysis(skip:boost)",
                          "解析が先頭でない [\(name)]: \(steps)")
        }
    }

    /// `drain` は**最後**で 1 回だけ（期限まで待つので、後ろに手は置けない）。
    func testDrainIsAlwaysLastAndOnce() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            XCTAssertEqual(steps.last, "drain", "drain が最後でない [\(name)]: \(steps)")
            XCTAssertEqual(steps.filter { $0 == "drain" }.count, 1,
                           "drain が 1 回でない [\(name)]: \(steps)")
        }
    }

    /// ⚠️ 回線が許可されていないなら、**通信する手は 1 つも並ばない**
    /// （「Wi-Fi のみ」の設定を破らない＝利用者の実費の問題・ADR-198）。
    func testNoNetworkStepsAppearWhenTheNetworkIsNotAllowed() {
        let networkOnly = ["shareImport", "shareSync", "publishAnalysis",
                           "reconcile", "captureDates"]
        for (name, inputs) in allInputs() where !inputs.networkAllowed {
            let steps = labels(inputs)
            for prefix in networkOnly {
                XCTAssertNil(index(steps, startingWith: prefix),
                             "回線が無いのに「\(prefix)」が並んだ [\(name)]: \(steps)")
            }
        }
    }

    /// ⚠️ 同じ手が 2 回並ばない（重複は「2 回払う」か「条件の書き漏れ」のどちらか）。
    func testNoStepAppearsTwice() {
        for (name, inputs) in allInputs() {
            let steps = labels(inputs)
            let dupes = Dictionary(grouping: steps, by: { $0 }).filter { $0.value.count > 1 }
            XCTAssertTrue(dupes.isEmpty, "同じ手が重複 [\(name)]: \(dupes.keys) / \(steps)")
        }
    }

    /// ⚠️ **導出された並びを目に見える形で固定する**（ADR-272）。
    ///
    /// 性質から導くようにすると、並びは `applicableSteps` を読んでも分からなくなる
    /// （そこは「どの手が当てはまるか」しか書いていない）。だから**全部入りの構成**で
    /// 結果を 1 本に書き出しておく——設計を変えたらここが落ちて、差分が目に入る。
    ///
    /// 読み方: `kick` → `work`（**上限つき** → 上限なし）→ `drain`。
    /// `publishAnalysis` は上限つきだが `after: [.shareImport]` で後ろへ送られている。
    func testDerivedOrderForTheFullConfiguration() {
        var inputs = NightlyPlan.Inputs(
            networkAllowed: true, provideShareEnabled: true,
            backupReconcileDue: true, publishAnalysisEnabled: true,
            captureDateBacklog: 1_000)
        inputs.embedBacklog = 0
        inputs.faceBacklog = 0
        inputs.availableMB = 2048
        XCTAssertEqual(labels(inputs), [
            "analysis",                                 // kick（投げっぱなし）
            "stallCheck", "indexSnapshot",              // work・上限つき
            "captureDates(\(NightlyPlan.captureDateProbeLimit))",
            "reconcile", "backup", "generate",          // work・上限なし
            "shareImport", "publishAnalysis",           // publish は after で import の直後へ
            "shareSync",
            "drain"                                     // drain（期限まで待つ）
        ])
    }

    /// ⚠️⚠️ **導出が収束していること**（ADR-272 追補・自分で見つけた穴）。
    ///
    /// `order(_:)` の `after` の解決は**回数に上限**を置いてある（回り続けないため）。
    /// つまり循環した前提（`A after B` と `B after A`）を宣言すると、
    /// **静かに誤った並びを返す**——例外も記録も出ない。
    /// だから「宣言した前提が、出てきた並びで全部満たされているか」を全組み合わせで確かめる。
    /// ⚠️ これは「どの `after` を書いたか」を**知らずに**働くので、
    /// 新しい前提を足しても自動的に見張られる（制約の一覧を書き写さない）。
    func testEveryDeclaredPrerequisiteIsSatisfiedInEveryConfiguration() {
        var checked = 0
        for (name, inputs) in allInputs() {
            let steps = NightlyPlan.steps(inputs)
            for (idx, step) in steps.enumerated() {
                for required in NightlyPlan.spec(for: step.kind).after {
                    guard let at = steps.firstIndex(where: { $0.kind == required }) else { continue }
                    checked += 1
                    XCTAssertLessThan(at, idx, """
                        宣言した前提が満たされていない（導出が収束していない）。
                        「\(step.label)」は \(required) の後ろでなければならない。
                        [\(name)] \(steps.map(\.label))
                        """)
                }
            }
        }
        // ⚠️ 前提が 1 つも現れない構成だけを見ていたら、このテストは空振りする。
        XCTAssertGreaterThan(checked, 0, "`after` の前提が 1 度も確かめられていない")
    }

    /// ⚠️ **網羅していることを assert する**（空でも通るテストを書かない・ADR-119）。
    /// 組み合わせを作る側が壊れたら、上の全テストが静かに空振りする。
    func testTheConfigurationSpaceIsActuallyCovered() {
        let all = allInputs()
        XCTAssertEqual(all.count, 192, "組み合わせの数が想定と違う（入力が増えた？）")
        let everyLabel = Set(all.flatMap { labels($0.inputs) })
        // 並びの制約が意味を持つには、制約の両側が**どこかの構成で**現れる必要がある。
        for required in ["analysis", "analysis(skip:boost)", "stallCheck", "indexSnapshot",
                         "backup", "generate", "shareImport", "shareSync",
                         "publishAnalysis", "reconcile", "drain"] {
            XCTAssertTrue(everyLabel.contains(required),
                          "「\(required)」がどの構成にも現れない＝その制約は試されていない")
        }
        XCTAssertTrue(everyLabel.contains { $0.hasPrefix("captureDates") },
                      "撮影日時がどの構成にも現れない")
        XCTAssertTrue(everyLabel.contains { $0.hasPrefix("generate(defer:") },
                      "生成の見送りがどの構成にも現れない")
        XCTAssertTrue(everyLabel.contains { $0.hasPrefix("generate(skip:") },
                      "空きメモリ不足の飛ばしがどの構成にも現れない")
    }
}
