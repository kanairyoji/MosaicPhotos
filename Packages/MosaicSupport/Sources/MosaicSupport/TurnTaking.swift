import Foundation

/// 「譲り続けたら必ず順番が回る」順番回しの純ロジック（ADR-87）。
///
/// 本プロジェクトは **同じ飢餓バグを 3 度**踏んだ:
/// - ADR-72: バックアップが CLIP 埋め込みに譲り続けて始まらない
/// - ADR-85: CLIP 埋め込みがシーンタグに譲り続けて数週間 0 枚
/// - ADR-86: VLM キャプションが顔スキャンに譲り続けて 1 枚も生成されず
///
/// いずれも「A が終わるまで B をやらない」と書いたが、**A が終わらない**（母数が数万枚・
/// 夜間の窓は数分）ため B が永久に動かなかった。判定をこの型に集約し、
/// 「連続 `maxDeferrals` 回譲ったら必ず取る」という不変条件をテストで固定する。
public enum TurnTaking {

    /// 今回の窓でこの処理が順番を取るか、と次回に持ち越す連続譲り回数。
    /// - Parameters:
    ///   - hasWork: 残作業があるか（無ければ順番を取る必要はない）
    ///   - blockedByOther: 他の処理を優先すべき状況か（例: 埋め込みの残作業がある／顔スキャン中）
    ///   - streak: これまでに連続して譲った回数
    ///   - maxDeferrals: 譲れる上限。これに達したら `blockedByOther` でも取る（飢餓防止）
    /// - Returns: `take`＝今回取るか、`streak`＝次回へ持ち越す連続譲り回数
    public static func nextTurn(hasWork: Bool, blockedByOther: Bool,
                                streak: Int, maxDeferrals: Int) -> (take: Bool, streak: Int) {
        guard hasWork else { return (false, streak) }        // 残作業なし＝譲り回数も増やさない
        if !blockedByOther { return (true, 0) }              // 誰も邪魔していない＝素直に取る
        if streak >= maxDeferrals { return (true, 0) }       // 譲りすぎ＝ここで必ず取る（飢餓防止）
        return (false, streak + 1)                          // 今回は譲る
    }
}
