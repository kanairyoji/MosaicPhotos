import Foundation

/// 「このアルバムはフル再評価が要るか」を決める純ロジック（ADR-160）。
///
/// ⚠️ ドリフト検知は**アルバム全体で 1 つ**の判定だった（保存済みの最小 `evaluatedEmbedCount`）。
/// そのため 1 本でも遅れていると、**追いついている残りのアルバムまで丸ごと再評価**していた。
/// 1 本の再評価は台帳の埋め込み（実機 85,090 件・約 1KB/件）を頭から流すので、
/// 5 本なら 5 周する——実機のディスク書き込み警告（33 分で 1.07GB・8/31 朝）の主因がこれ。
/// 判定を**アルバム単位**にすれば、遅れている本数ぶんしか流さない。
public enum AIAlbumDrift {

    /// - Parameters:
    ///   - version: 保存済み解釈の版（nil = 旧版）。
    ///   - evaluatedEmbedCount: この解釈が評価済みの埋め込み数。
    ///   - embedCount: 現在の埋め込み総数。
    ///   - threshold: この差を超えたら再評価する（既定 500）。
    public static func needsFullEvaluation(version: Int?,
                                           currentVersion: Int = SavedInterpretation.currentVersion,
                                           spec: QuerySpec,
                                           lastEvaluatedAt: Date?,
                                           evaluatedEmbedCount: Int,
                                           embedCount: Int,
                                           threshold: Int,
                                           now: Date,
                                           calendar: Calendar = .current) -> Bool {
        // 評価**規則**が変わった（解釈器の版上げ）ものは、埋め込みの進行に関係なく作り直す。
        if version != currentVersion { return true }
        // 「直近 30 日」等は時間が経つだけで範囲が動く。日をまたいだら作り直す。
        if RelativeDateStaleness.needsRefresh(spec: spec, lastEvaluatedAt: lastEvaluatedAt,
                                              now: now, calendar: calendar) { return true }
        return embedCount - evaluatedEmbedCount > threshold
    }
}
