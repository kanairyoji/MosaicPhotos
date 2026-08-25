import Foundation

/// 相対日付アルバムの「時間が経っただけで古くなる」判定（純ロジック・テスト対象）。
///
/// ⚠️ 「直近 30 日」「今年」のような条件は、**写真が増えなくても範囲が動く**。
/// ドリフト検知は埋め込み枚数の差しか見ておらず、増分評価は既存メンバーを維持するため、
/// 期間外になった写真がアルバムに残り続ける（レビュー指摘）。日付の境界を越えたら再評価する。
public enum RelativeDateStaleness {

    /// この条件は時間で動くか（`lastDays` / `lastMonths` / `lastYears` / `year`）。
    /// `year` も年をまたぐと「今年」の意味が変わるため対象に含める。
    public static func isTimeDependent(_ range: AIAlbumDateRange) -> Bool {
        switch range.kind {
        case .absolute: return false
        case .year, .lastYears, .lastMonths, .lastDays: return true
        }
    }

    /// 仕様に時間依存の日付条件が含まれるか。
    public static func hasTimeDependentDate(_ spec: QuerySpec) -> Bool {
        spec.clauses.contains { clause in
            clause.conditions.contains { condition in
                if case .date(let range) = condition { return isTimeDependent(range) }
                return false
            }
        }
    }

    /// 再評価が要るか（前回のフル評価から**日付が変わった**か）。
    /// - 前回評価の記録が無い（旧データ）→ 要再評価（1 回だけ移行させる）。
    /// - 時間依存の条件が無い → 不要（写真が増えたときのドリフト検知に任せる）。
    public static func needsRefresh(spec: QuerySpec, lastEvaluatedAt: Date?, now: Date,
                                    calendar: Calendar = .current) -> Bool {
        guard hasTimeDependentDate(spec) else { return false }
        guard let lastEvaluatedAt else { return true }
        return !calendar.isDate(lastEvaluatedAt, inSameDayAs: now)
    }
}
