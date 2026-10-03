import Foundation

/// 「動くべき解析パスが、実際には長期間動いていない」ことを検出する純ロジック（ADR-87）。
///
/// 飢餓バグ（ADR-72/85/86）はいずれも**沈黙として現れた**——ログに何も出ないので、
/// 実機ログを見ても「動いていない」ことに気づけず、数週間放置された。
/// 「残作業があるのに最後の処理から N 日以上経っている」パスを機械的に洗い出し、
/// 診断ログと Developer Options に出して、次からは沈黙のまま見逃さないようにする。
public enum AnalysisStallCheck {

    /// 1 パス分の状態（残作業と最終処理時刻）。
    public struct PassState: Sendable, Equatable {
        public let pass: AnalysisActivity.Pass
        /// 残っている枚数。
        /// - 0: やることが無い（＝停滞ではない）
        /// - nil: **分からない**（まだ測っていない）
        ///
        /// ⚠️ **nil と 0 を同じ扱いにしない**（ADR-207/252/253）。ここが `Int` だったとき、
        /// 呼び出し側は「分からない」を渡す手段が無いので `?? 0` で潰すほかなく、
        /// **顔の停滞は一度も検出できなかった**——沈黙を検出しにいく仕組みが、
        /// それ自体沈黙していた。分からないなら「分からない」と言えるようにする。
        public let pending: Int?
        /// 最後に 1 枚以上処理した時刻（一度も処理していなければ nil）。
        public let lastActivity: Date?

        public init(pass: AnalysisActivity.Pass, pending: Int?, lastActivity: Date?) {
            self.pass = pass
            self.pending = pending
            self.lastActivity = lastActivity
        }
    }

    /// 停滞とみなすまでの猶予。夜間の窓は毎晩来るので、3 日動いていなければ異常。
    public static let defaultGrace: TimeInterval = 3 * 24 * 60 * 60

    /// 停滞しているパスを返す（残作業あり × 猶予超過）。
    /// - `installedAt`: この端末で解析が始まり得た時刻の下限（アプリ導入・版上げ）。
    ///   一度も動いていないパスは、ここからの経過で判定する（新規インストール直後の誤検知を防ぐ）。
    public static func stalled(_ states: [PassState], now: Date,
                               installedAt: Date? = nil,
                               grace: TimeInterval = defaultGrace) -> [AnalysisActivity.Pass] {
        states.compactMap { state in
            // ⚠️ 「やることが無い（0）」だけを除く。**「分からない（nil）」は通す**
            // ——分からないまま猶予を超えて動いていないのは、まさに検出したい沈黙そのもの
            // （ADR-253）。呼び出し側は「work が起こり得ない」ときに 0 を渡す責任を持つ。
            guard state.pending != 0 else { return nil }
            let reference = state.lastActivity ?? installedAt
            guard let reference else { return nil }                  // 基準が無い＝判定しない
            return now.timeIntervalSince(reference) > grace ? state.pass : nil
        }
    }

    /// 診断ログ 1 行（停滞が無ければ nil＝ログを汚さない）。
    public static func logLine(_ states: [PassState], now: Date,
                               installedAt: Date? = nil,
                               grace: TimeInterval = defaultGrace) -> String? {
        let bad = stalled(states, now: now, installedAt: installedAt, grace: grace)
        guard !bad.isEmpty else { return nil }
        let detail = bad.compactMap { pass -> String? in
            guard let state = states.first(where: { $0.pass == pass }) else { return nil }
            let reference = state.lastActivity ?? installedAt
            let days = reference.map { Int(now.timeIntervalSince($0) / 86_400) }
            // ⚠️ 分からない残作業は `?` と出す。`?? 0` にすると「pending=0 なのに停滞」という
            // 読めない行になり、原因を追う側が「検査が壊れている」と誤解する（ADR-253）。
            let pending = state.pending.map(String.init) ?? "?"
            return "\(pass.rawValue)(pending=\(pending) idle=\(days.map(String.init) ?? "?")d)"
        }
        return "analysis STALLED — " + detail.joined(separator: " ")
    }
}
