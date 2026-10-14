import Foundation

/// バックアップが終わったとき、共有の反映を起こすか（diagnostics-109）。
///
/// ## なぜ要るか
/// この合図の役目は「**バックアップ待ち**だった共有写真を反映する」だけ。ところが無条件に
/// 起こしていたので、待ちが 0 枚の夜も窓ごとに**全件の一覧を取り直す反映がもう 1 回**走っていた
/// （夜間の手の反映と合わせて毎窓 2 回・どちらも `copy=0 delete=0`）。
///
/// ## 材料
/// セットごとの控え（`ShareSet.lastSyncedWaiting`・前の反映が数えた待ちの数）。
/// ⚠️ バックアップの「上がった枚数」は使わない——OS へ預けた分（spool）を数えないので、
/// 0 枚でも記録が増えることがある。待ちが無ければ、何が上がっても反映できる写真は増えない。
/// ⚠️ **分からないは「起こす」**（従来どおり）: 読めない・まだ数えていないセットがある。
public enum ShareAfterBackupGate {
    /// - Parameter waitingBackup: セットごとの待ちの数（nil＝まだ数えていない）。全体が nil＝読めない。
    public static func shouldSync(waitingBackup: [Int?]?) -> Bool {
        guard let waitingBackup else { return true }
        return waitingBackup.contains { ($0 ?? 1) > 0 }
    }
}
