import Foundation
@testable import MosaicPhotos

/// **夜の窓を模して回す**（ADR-274）。並びではなく「**順番が回ったか**」で測る。
///
/// ⚠️⚠️ なぜ要るか（照合した結果）
/// このセッションの欠陥 13 件のうち **7 件**はこれで捕まる。とくに直近の重い 2 件——
/// ADR-270（手を `shareSync` の後ろに置き、提供オンの端末で**一度も走らない**）と
/// ADR-273（`backup` を「上限なし」と宣言し、短い窓で**その晩 1 枚も進まない**）——は
/// **どちらもテストでは捕まらず、独立レビューで見つかった**。
///
/// ⚠️ 並びのテスト（`NightlyPlanOrderingTests`）は強力だが、
/// **「どの対が重要か」を人が列挙する**必要がある。実際 ADR-273 では
/// その列挙自体が間違っていた（`windowEating` に `backup` を入れていた）。
/// こちらは「**全部の手に順番が回ったか**」だけを訊くので、どの対が重要かを知らなくてよい
/// ——規則を列挙するより結果を測る方が、**知らない穴に強い**（ADR-251 と同じ構図）。
///
/// ## 作りの決め
/// - ⚠️ **本番の判断をそのまま呼ぶ**（`NightlyPlan.steps`）。模すのは**効果だけ**。
///   さもないと「シミュレータをテストする」ことになる。
/// - ⚠️⚠️ **手の所要は `Cost` の宣言から導く**（秒数を書き写さない）。
///   この一手で**宣言が自己検査になる**——`backup` を `.unbounded` と偽れば飢餓として出る。
/// - 測るのは**回数**と**残作業の推移**。時間ではない（ADR-119 と同じ規律）。
///
/// ## 何が捕まらないか（売り込まない）
/// 実際の所要・メモリ・iOS の気分・API の実挙動。⚠️ **実機ログの代わりにはならない**。
/// ⚠️ とくに「手が宣言した上限を**破る**」バグは原理的に見えない
/// （この模型は宣言を正しいものとして扱うから）。
struct NightlyWindowSimulator {

    /// **実測の窓の長さ**（diagnostics-106/107 の 23 窓）。
    /// ⚠️ 1 つの数を当てるのではなく**幅を掃く**——ここが
    /// 「時間割り当てスケジューラは採らない」（ADR-272）と両立する理由。
    /// あちらは所要を**実行時**に要るので成立しないが、こちらは**テストの中**だけ。
    static let measuredWindowSeconds: [TimeInterval] =
        [21, 27, 31, 43, 48, 57, 142, 153, 157, 160, 173, 197, 213, 284]

    /// 窓の中で 1 手が返るまでの秒数。**`Cost` の宣言から導く**。
    ///
    /// ⚠️ `.bounded` の実際の秒数は手ごとに違うが、**結論に効くのは
    /// 「上限つきは窓より小さい」という性質**なので、分かっているものだけ本番の定数を読み、
    /// 他は小さい既定値にする（ここに表を作らない＝速さの第 2 の出典を作らない）。
    static func seconds(for kind: NightlyPlan.Kind, remaining: TimeInterval) -> TimeInterval {
        switch NightlyPlan.spec(for: kind).cost {
        case .nonblocking:
            // 投げっぱなし（即座に返る）。仕事は裏で続くが、窓は塞がない。
            return 0
        case .bounded:
            // 宣言された上限。⚠️ 撮影日時は**本番の定数**を読む（ADR-257 の 40 秒）。
            if kind == .captureDates { return HeavyWorkScheduler.captureDateProbeSeconds }
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
        /// 各手が走った回数（手の種類ごと）。
        var executed: [NightlyPlan.Kind: Int] = [:]
        /// 1 窓も走らなかった手（最後の窓の結果）。
        var missedLastWindow: Set<NightlyPlan.Kind> = []

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
    var availableMB = 2048

    /// 1 つの窓を回す。
    /// - Returns: その窓で**順番が回った**手（種類）。
    @discardableResult
    mutating func runWindow(seconds windowLength: TimeInterval,
                            reconcileDue: Bool = false) -> Set<NightlyPlan.Kind> {
        let inputs = NightlyPlan.Inputs(
            embedBacklog: world.embedBacklog,
            faceBacklog: world.faceBacklog,
            generateDeferrals: world.generateDeferrals,
            availableMB: availableMB,
            networkAllowed: networkAllowed,
            provideShareEnabled: provideShareEnabled,
            backupReconcileDue: reconcileDue,
            publishAnalysisEnabled: publishAnalysisEnabled,
            captureDateBacklog: world.captureDateBacklog)

        // ⚠️ **本番の判断**をそのまま使う。
        let steps = NightlyPlan.steps(inputs)
        let planned = Set(steps.map(\.kind))

        var clock: TimeInterval = 0
        var ran: Set<NightlyPlan.Kind> = []
        for step in steps {
            // 本番の輪と同じ形: 1 手ごとに「まだ窓があるか」を見る
            // （`guard !Task.isCancelled else { break }`）。
            guard clock < windowLength else { break }
            ran.insert(step.kind)
            world.executed[step.kind, default: 0] += 1
            apply(step)
            clock += Self.seconds(for: step.kind, remaining: windowLength - clock)
        }
        world.missedLastWindow = planned.subtracting(ran)
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
    private mutating func apply(_ step: NightlyPlan.Step) {
        switch step {
        case .probeCaptureDates(let limit):
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

    /// `everyWindow` を宣言した手のうち、計画に載っていたのに**順番が回らなかった**もの。
    func starvedEveryWindowSteps() -> Set<NightlyPlan.Kind> {
        world.missedLastWindow.filter { NightlyPlan.spec(for: $0).everyWindow }
    }
}
