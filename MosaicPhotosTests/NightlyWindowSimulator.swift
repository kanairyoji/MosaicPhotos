import Foundation
@testable import MosaicPhotos

/// **夜の窓を模して回す**（ADR-274）。並びではなく「**順番が回ったか**」で測る。
///
/// ⚠️⚠️ なぜ要るか（ADR-274 追補 2）
/// `NightlyPlanOrderingTests` の `windowEating` は「上限なしの手」の一覧なので、
/// **撮影日時（`.bounded` だが 40 秒）が入っていない**。ところが実測で最短の窓は 21 秒なので、
/// 撮影日時の後ろに置かれた毎窓の手は**実際に飢えるのに、その制約は素通りする**
/// ＝「上限つき／上限なし」の 2 値では足りない。
/// ⚠️ **訂正**: ここに「並びのテストは通り、この模型は落ちる」と書いたが**誤り**だった
/// （2 周目のレビューが実測）。全部入りの並びを 1 本の golden list で持つ
/// `testDerivedOrderForTheFullConfiguration` は落ちる。ただし golden list は
/// 意図した変更のときに書き換えるものなので、**制約の代わりにはならない**。
///
/// ⚠️ 並びのテストは強力だが「**どの対が重要か**」を人が列挙する必要があり、
/// 実際 ADR-273 ではその列挙自体が間違っていた（`windowEating` に `backup` を入れていた）。
/// こちらは「**宣言した手に**順番が回ったか」だけを訊くので、どの対が重要かを知らなくてよい
/// （⚠️ 「全部の手に」ではない——`everyWindow` と宣言した手だけ）。
///
/// ## 作りの決め
/// - ⚠️ **本番の判断をそのまま呼ぶ**（`NightlyPlan.steps`）。模すのは**効果だけ**。
/// - ⚠️⚠️ **手の所要は `Cost` の宣言から導く**（秒数を書き写さない）。
///   この一手で**宣言が自己検査になる**——`backup` を `.unbounded` と偽れば飢餓として出る。
/// - ⚠️ 偽りは**本番の `spec(for:)` の seam**（`NightlyPlan.specOverrideForTesting`）に入れる。
///   模型の側に別の口を作った版では、偽りが `order` に**届かず並びが変わらなかった**ため、
///   「過去の欠陥を再現する」はずのテストが別の仕組みで通っていた（独立レビュー 2 件が指摘）。
/// - 測るのは**回数**と**残作業の推移**。時間ではない（ADR-119 と同じ規律）。
///
/// ## 何が捕まらないか（売り込まない・独立レビュー 3 件の監査を反映）
/// 1. ⚠️⚠️ **宣言が実態より小さいバグは原理的に見えない**（模型は宣言を正しいものとして扱う）。
///    ⚠️ これは仮定の話ではない: `.analysis` は `.nonblocking` と宣言しているが、本番は
///    `await kick(.window)` で 8.5 万件の列挙を待つ（実測 11〜38 秒）。21 秒の窓なら
///    **1 手目で窓が尽きる**。`analysisKickSeconds` を入れるとその世界を見られる。
/// 2. ⚠️ **効果を模しているのは 11 手のうち 4 手**（`default: break`）。残作業の assert に
///    歯があるのは撮影日時だけ。控えの鍵・圧迫の出来事・起動回数は世界に無い
///    （＝ADR-258/260/266/267 は**この模型では捕まらない**。拡張の余地として残す）。
/// 3. ⚠️ **効果は満額入る**。21 秒の窓で 40 秒の手に順番が回ると「500 枚進んだ」ことになる。
///    「順番は回ったが窓が短くて 10 枚しか進まない」（＝ADR-257 の症状そのもの）は見えない。
/// 4. ⚠️ `Cost.bounded` は**大きさを持たない**。本番の定数を読むのは撮影日時（40 秒）だけで、
///    他は 1 秒と仮定する＝**楽観側**。だから「上限つきは窓より小さい」はこの模型の中でだけ真。
/// 5. ⚠️ `faceBacklog` の **nil（分からない・ADR-252）は表現できない**（`Int` で持っている）。
/// 6. 実所要・メモリ・iOS の気分・API の実挙動・前面復帰による途中打ち切り。
/// ⚠️ **実機ログの代わりにはならない。**
struct NightlyWindowSimulator {

    /// **実測の窓の長さ**（diagnostics-106/107 の 23 窓のうち、**重複を除いた 14 の長さ**）。
    /// ⚠️ 1 つの数を当てるのではなく**幅を掃く**——ここが
    /// 「時間割り当てスケジューラは採らない」（ADR-272）と両立する理由。
    /// あちらは所要を**実行時**に要るので成立しないが、こちらは**テストの中**だけ。
    static let measuredWindowSeconds: [TimeInterval] =
        [21, 27, 31, 43, 48, 57, 142, 153, 157, 160, 173, 197, 213, 284]

    // MARK: - 宣言を偽る（模型自身の有効性を固定するため）

    /// 宣言を偽った世界で `body` を回す（抜けるとき必ず戻す）。
    ///
    /// ⚠️⚠️ 偽りは**本番の `spec(for:)`**（`NightlyPlan.specOverrideForTesting`・`#if DEBUG`）に
    /// 入れる。ここが要点——`order` も `applicableSteps` も `spec(for:)` 越しに読むので、
    /// 偽りが**並びの導出まで届く**。模型の側に別の口を作った版では届かず、
    /// 「`backup` を上限なしと偽る」テストは**並びが変わらないまま**、
    /// 「早く置かれた手が後ろを飢えさせた」という**別の仕組み**で通っていた。
    static func withSpecOverride(_ override: @escaping (NightlyPlan.Kind) -> NightlyPlan.Spec?,
                                 _ body: () -> Void) {
        let saved = NightlyPlan.specOverrideForTesting
        NightlyPlan.specOverrideForTesting = override
        defer { NightlyPlan.specOverrideForTesting = saved }
        body()
    }

    /// `kind` の **`cost` だけ**を偽った世界で `body` を回す（退行シナリオはこれを使う）。
    ///
    /// ⚠️⚠️ **偽りの `Spec` はスコープに入る前に組む**。`spec(for:)` を偽りの**中**で呼ぶと
    /// 自分の偽りを読み返して**無限再帰**する——実際に踏んだ（3 本が 0.000 秒で落ちた）。
    /// 「偽りを組む道具」を呼び側に書かせると必ずこれを踏むので、
    /// 偽りの作り方ごとここに閉じ込める（ADR-196: 判断を関数にして呼び側に書かせない）。
    /// ⚠️ `Spec(...)` を手で組み直さないのも同じ理由——`everyWindow` を落とすと
    /// 飢餓の assert が静かに意味を失う（偽りの作り方そのものが罠になる）。
    static func withCostOverride(_ cost: NightlyPlan.Cost, for kind: NightlyPlan.Kind,
                                 _ body: () -> Void) {
        var faked = NightlyPlan.spec(for: kind)   // ← まだ偽りは入っていない
        faked.cost = cost
        withSpecOverride({ $0 == kind ? faked : nil }, body)
    }

    // MARK: - 手の所要（`Cost` の宣言から導く）

    /// 窓の中で 1 手が返るまでの秒数。**`Cost` の宣言から導く**。
    ///
    /// ⚠️ `Kind` ではなく **`Step`** を受ける。`Kind.generate` は `.unbounded` だが、
    /// `.deferGenerate` / `.skipGenerateLowMemory` は `UserDefaults` に 1 つ書いてログを出すだけ
    /// ＝ほぼ 0 秒。`Kind` で丸めた版は「見送り」にも窓を全部使わせていた（独立レビューの指摘）。
    /// ADR-163 は 5 窓のうち 4 窓まで見送り得るので、**ふだんの窓を最も悲観的に誤る**形だった。
    static func seconds(for step: NightlyPlan.Step, remaining: TimeInterval) -> TimeInterval {
        // 「決めてログを出すだけ」の手は、種類の宣言に関わらず窓を塞がない。
        switch step {
        case .deferGenerate, .skipGenerateLowMemory, .skipAnalysisBoostActive:
            return 0
        default:
            break
        }
        switch NightlyPlan.spec(for: step.kind).cost {
        case .nonblocking:
            // 投げっぱなし（即座に返る）。仕事は裏で続くが、窓は塞がない。
            return 0
        case .bounded:
            // 宣言された上限。⚠️ 撮影日時は**本番の定数**を読む（ADR-257 の 40 秒）。
            // ⚠️ 他は 1 秒と**仮定**する（`Cost.bounded` が大きさを持たないので導けない）。
            //    `NightlyWindowSimulationTests` がこの 2 つを両方 pin する——
            //    どちらを落としても模型は黙って green になる（変異 M3/M5・独立レビューの実測）。
            if step.kind == .captureDates { return HeavyWorkScheduler.captureDateProbeSeconds }
            return 1
        case .unbounded:
            // 窓の期限まで走り得る＝**残り全部**（後ろの手には順番が回らない）。
            return remaining
        }
    }

    /// 模した世界（残作業と実行回数）。⚠️ 本番の状態を写すのではなく、
    /// **assert したい事実**（飢餓・残作業の推移）だけを持つ。
    struct World {
        var captureDateBacklog: Int
        var embedBacklog: Int
        var faceBacklog: Int
        var generateDeferrals: Int
        /// 各手が走った回数（手の種類ごと）。⚠️ **回数で測る**ため（ADR-119）。
        var executed: [NightlyPlan.Kind: Int] = [:]
        /// 窓ごとの飢餓（**上書きしない**＝何晩か回した後も各窓を見られる）。
        var starvedByWindow: [Set<NightlyPlan.Kind>] = []

        init(captureDateBacklog: Int = 0, embedBacklog: Int = 0, faceBacklog: Int = 0) {
            self.captureDateBacklog = captureDateBacklog
            self.embedBacklog = embedBacklog
            self.faceBacklog = faceBacklog
            self.generateDeferrals = 0
        }
    }

    var world: World
    var networkAllowed = true
    var provideShareEnabled = false
    var publishAnalysisEnabled = false
    var boostActive = false
    var availableMB = 2048

    /// ⚠️ **1 手目（解析を起こす）が窓を食う世界**を見るための値（既定 0＝宣言どおり）。
    /// 本番は `await kick(.window)` で 8.5 万件の列挙を待ち、実測 11〜38 秒かかる
    /// （`AnalysisDriver` の「8.5 万件・約 11 秒」・`candidates.cloudRefs` が 3.7→38 秒）。
    /// 宣言は `.nonblocking` なので模型は既定で 0 秒と見る＝**この世界は見えない**。
    /// `NightlyWindowSimulationTests` がここを上げて「何が起きるか」を測り、
    /// 実機の確認（`device-verification.md`）に予測を渡す。
    var analysisKickSeconds: TimeInterval = 0

    // MARK: - 計画

    func inputs(reconcileDue: Bool = false) -> NightlyPlan.Inputs {
        NightlyPlan.Inputs(
            boostActive: boostActive,
            embedBacklog: world.embedBacklog,
            faceBacklog: world.faceBacklog,
            generateDeferrals: world.generateDeferrals,
            availableMB: availableMB,
            networkAllowed: networkAllowed,
            provideShareEnabled: provideShareEnabled,
            backupReconcileDue: reconcileDue,
            publishAnalysisEnabled: publishAnalysisEnabled,
            captureDateBacklog: world.captureDateBacklog)
    }

    /// その窓の計画（**本番の判断**）。退行シナリオが「当時の並び」を作る土台にも使う。
    func plan(reconcileDue: Bool = false) -> [NightlyPlan.Step] {
        NightlyPlan.steps(inputs(reconcileDue: reconcileDue))
    }

    /// この構成で**順番が回らなければならない**手。
    ///
    /// ⚠️⚠️ **導出は本番（`NightlyPlan.requiredEveryWindowKinds`）にある**。ここに写さない——
    /// 同じ導出を模型にも持っていた版では、**本番の飢餓ログに照合週の免除が無く**、
    /// 模型と実機で判断が食い違っていた（ADR-196 の形・ADR-274 追補 2 で寄せた）。
    static func requiredEveryWindowSteps(in plan: [NightlyPlan.Step],
                                        networkAllowed: Bool) -> Set<NightlyPlan.Kind> {
        NightlyPlan.requiredEveryWindowKinds(in: plan, networkAllowed: networkAllowed)
    }

    // MARK: - 窓を回す

    /// 1 つの窓を回す（**本番の計画**で）。
    /// - Returns: その窓で**順番が回った**手（種類）。
    @discardableResult
    mutating func runWindow(seconds windowLength: TimeInterval,
                            reconcileDue: Bool = false) -> Set<NightlyPlan.Kind> {
        runWindow(plan: plan(reconcileDue: reconcileDue), seconds: windowLength)
    }

    /// ⚠️ **並びを外から与えて**回す（退行シナリオ専用）。
    ///
    /// なぜ要るか: ADR-270 の実バグは「手の**位置**が悪かった」だが、導出方式（ADR-272）では
    /// 位置を手で指定できない。当時の並びを**データとして**与えるのが唯一の忠実な再現。
    @discardableResult
    mutating func runWindow(plan steps: [NightlyPlan.Step],
                            seconds windowLength: TimeInterval) -> Set<NightlyPlan.Kind> {
        var clock: TimeInterval = 0
        var ran: Set<NightlyPlan.Kind> = []
        for step in steps {
            // 本番の輪と同じ形: 1 手ごとに「まだ窓があるか」を見る
            // （`guard !Task.isCancelled else { break }`・確認は手の**前**）。
            guard clock < windowLength else { break }
            ran.insert(step.kind)
            world.executed[step.kind, default: 0] += 1
            apply(step)
            clock += Self.seconds(for: step, remaining: windowLength - clock)
            if step.kind == .analysis { clock += analysisKickSeconds }
        }
        let required = Self.requiredEveryWindowSteps(in: steps, networkAllowed: networkAllowed)
        world.starvedByWindow.append(required.subtracting(ran))
        return ran
    }

    /// 何晩か回す（窓の長さは実測の幅を順に使う）。
    mutating func runNights(_ count: Int, windowsPerNight: Int = 3,
                            reconcileOnFirstNight: Bool = false) {
        var lengthIndex = 0
        for night in 0..<count {
            for window in 0..<windowsPerNight {
                let length = Self.measuredWindowSeconds[lengthIndex % Self.measuredWindowSeconds.count]
                lengthIndex += 1
                runWindow(seconds: length,
                          reconcileDue: reconcileOnFirstNight && night == 0 && window == 0)
            }
        }
    }

    /// 手の**効果**を世界へ反映する。⚠️ ここは模型なので、
    /// 本番と同じ量を再現しようとしない（減り方の向きと上限だけ合わせる）。
    /// ⚠️ 模しているのは 11 手のうち 4 手だけ（限界 2）。
    private mutating func apply(_ step: NightlyPlan.Step) {
        switch step {
        case .probeCaptureDates(let limit):
            // ⚠️ 満額減らす（限界 3: 窓の残りに応じた目減りは見ない）。
            world.captureDateBacklog = max(0, world.captureDateBacklog - limit)
        case .generate:
            world.generateDeferrals = 0
        case .deferGenerate(let streak):
            world.generateDeferrals = streak
        case .startAnalysis:
            // 解析は投げっぱなしで、裏で少しずつ進む（量は模型の値）。
            world.embedBacklog = max(0, world.embedBacklog - 200)
            world.faceBacklog = max(0, world.faceBacklog - 200)
        default:
            break
        }
    }

    // MARK: - 読み出し

    /// 回した窓の数。⚠️ 飢餓の assert が**空振りしていない**ことの確認に使う。
    var windowsRun: Int { world.starvedByWindow.count }

    /// 直前の窓で、順番が回らなければならないのに回らなかった手。
    ///
    /// ⚠️ 1 窓も回していないのに訊くのは**空振り**（新しい模型に訊くと常に空集合になる）。
    /// CLAUDE.md の「空でも通る assert を書かない」に従って、ここで止める。
    func starvedEveryWindowSteps() -> Set<NightlyPlan.Kind> {
        precondition(!world.starvedByWindow.isEmpty,
                     "まだ 1 窓も回していない（`runWindow` を呼ぶ前に飢餓を訊いている＝空振り）")
        return world.starvedByWindow[world.starvedByWindow.count - 1]
    }

    /// 回した**すべての窓**で一度でも飢えた手（何晩か回したときに使う）。
    func starvedInAnyWindow() -> Set<NightlyPlan.Kind> {
        precondition(!world.starvedByWindow.isEmpty, "まだ 1 窓も回していない＝空振り")
        return world.starvedByWindow.reduce(into: Set<NightlyPlan.Kind>()) { $0.formUnion($1) }
    }
}
