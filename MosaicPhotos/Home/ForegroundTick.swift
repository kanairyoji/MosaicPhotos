import Foundation
import MosaicSupport

/// ホームの前面の定期ループ（場所の再スキャン・撮影日時の穴埋め・自動アルバムの再生成）の
/// 「この回に走ってよいか」と「次にどれだけ眠るか」。
///
/// 以前は 3 本のループが `HomeView` の中で同じ判断（背面では判断しない・`.cloudTrickle`・
/// 眠る間隔）を書き写しており、ビューの中なのでテストが無かった（ADR-196 の形）。
/// 判断はここ（純ロジック）、ループの骨格は `run(_:)`、各ループは `Spec` で宣言するだけ。
enum ForegroundTick {

    /// この回に走るために要る条件。
    enum Requirement: Hashable {
        /// 重い処理の中央ゲート（電源＋回線＋非操作）。通信を伴う処理（逆ジオコーディング・`get_metadata`）。
        case cloudTrickle
        /// Dropbox に接続済み。
        case dropboxConnected
    }

    /// 判断の材料（実行時の事実）。
    struct Environment: Equatable {
        var isInBackground: Bool
        var allowsCloudTrickle: Bool
        var isDropboxConnected: Bool
    }

    /// この回に走ってよいか。
    /// ⚠️ 背面では**どの要求でも**走らない。吊るされていたループは BGTask がプロセスを起こした
    /// 瞬間に「期限超過」で発火し、処理枠側の判断（`NightlyWorkPolicy`）を素通りしていた
    /// （diagnostics-74）。背面の仕事は `HeavyWorkScheduler` だけが起こす。
    static func shouldRun(requires: Set<Requirement>, _ env: Environment) -> Bool {
        guard !env.isInBackground else { return false }
        for requirement in requires {
            switch requirement {
            case .cloudTrickle where !env.allowsCloudTrickle: return false
            case .dropboxConnected where !env.isDropboxConnected: return false
            default: continue
            }
        }
        return true
    }

    /// 1 回ぶんの結果。
    enum Outcome: Equatable {
        /// 走らなかった（条件が揃わない）。
        case skipped
        /// 走った。続きが残っているなら `hasMore`。
        case ran(hasMore: Bool)
    }

    /// 次に眠る秒数。続きが残っているときだけ短い間隔で次の塊へ進む（急がない既定は `interval`）。
    static func nextDelay(after outcome: Outcome, interval: Int, busyInterval: Int?) -> Int {
        if case .ran(hasMore: true) = outcome, let busyInterval { return busyInterval }
        return interval
    }

    /// 1 本のループの宣言。
    struct Spec {
        /// 起動直後の山を避けるための初回の遅れ（秒）。
        var initialDelay: Double
        /// 初回の遅れの後に 1 回だけ無条件で走る処理（キャッシュの読み込み・初回スキャン）。
        var start: (@MainActor () async -> Void)?
        /// 最初の判断の前に `interval` だけ眠るか（`start` の直後に同じ仕事を繰り返さない）。
        var sleepsBeforeFirstTick: Bool
        var requires: Set<Requirement>
        /// 続きが残っているときの間隔（秒）。nil なら常に `interval`。
        var busyInterval: Int?
        /// 1 回ぶんの仕事。続きが残っているなら true。
        var tick: @MainActor () async -> Bool
    }

    /// ループの骨格。キャンセルで抜ける。`interval` と `environment` は毎回読み直す
    /// （設定の変更・電源や回線の変化を次の回から反映する）。
    @MainActor
    static func run(_ spec: Spec, interval: () -> Int, environment: () -> Environment) async {
        try? await Task.sleep(for: .seconds(spec.initialDelay))
        if let start = spec.start { await start() }
        var delay = spec.sleepsBeforeFirstTick ? interval() : 0
        while !Task.isCancelled {
            // 0 秒でも必ず一度は手放す（条件が揃わない回が続いても MainActor を回し続けない）。
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) } else { await Task.yield() }
            guard !Task.isCancelled else { return }
            let outcome: Outcome
            if shouldRun(requires: spec.requires, environment()) {
                outcome = .ran(hasMore: await spec.tick())
            } else {
                outcome = .skipped
            }
            delay = nextDelay(after: outcome, interval: interval(), busyInterval: spec.busyInterval)
        }
    }
}
