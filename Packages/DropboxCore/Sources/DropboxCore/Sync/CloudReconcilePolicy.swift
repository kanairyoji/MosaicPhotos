import Foundation

/// **クラウドのキャッシュを、いつ全件見直すか**（ADR-206・純ロジック・テスト対象）。
///
/// 差分同期（longpoll → `list_folder/continue`）は「消えた」通知を**一度でも取りこぼすと**
/// その行が永久に残る。一覧には出るのに開けない写真になる（実機で確認＝diagnostics-82）。
/// バックアップ台帳には週 1 回の照合があるのに、クラウドのキャッシュには無かった。
///
/// ⚠️ 「最後にいつ全件を見たか」は新しく持たない。`DropboxSyncState.initialSyncCompletedAt`
/// が**まさにその時刻**（初回同期の Step 4 で一覧と突き合わせて掃除し終えた時刻）なので、
/// それを読むだけで足りる。掃除の処理そのものも初回同期が持っている——つまり
/// 「期限が来たら初回同期をやり直す」だけで照合になる。
enum CloudReconcilePolicy {

    /// 全件の見直し間隔（7 日）。バックアップ台帳の照合と揃えてある。
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// - Parameter lastFullScan: 最後に全件を見終えた時刻（nil＝一度も完走していない）。
    ///
    /// ⚠️ nil は **false** を返す。「一度も完走していない」の扱いは呼び出し側が既に持っていて
    /// （カーソル・件数・完走の印で初回同期へ分岐する）、ここで true を返すと
    /// その判断と二重になる。ここが答えるのは「完走済みだが古くなったか」だけ。
    static func isDue(lastFullScan: Date?, now: Date,
                      interval: TimeInterval = CloudReconcilePolicy.interval) -> Bool {
        guard let lastFullScan else { return false }
        // ⚠️ 端末の時計が巻き戻ることはある。差が負なら「間隔が空いた」と扱う
        //（巻き戻りで永久に照合されない方が困る）。`BackupReconcilePolicy` と同じ規則。
        let elapsed = now.timeIntervalSince(lastFullScan)
        return elapsed < 0 || elapsed >= interval
    }
}
