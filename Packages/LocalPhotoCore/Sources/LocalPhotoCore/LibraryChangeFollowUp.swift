import Foundation

/// 写真ライブラリの変更にどう追従するかの判定（純ロジック・テスト対象）。
///
/// ⚠️ 起動時に一度読むだけ／TTL だけで判断する作りは、**表示中の撮影・取り込み・削除・
/// 限定アクセスの範囲変更・アルバム構成の変更**を取りこぼす（レビュー指摘）。
/// 変更通知で印を立て、ここで「再スキャンすべきか」を決める。
public enum LibraryChangeFollowUp {

    /// キャッシュを使ってよいか（＝再スキャンが不要か）。
    /// - Parameters:
    ///   - scannedAt: キャッシュを作った時刻。
    ///   - isDirty: 前回のスキャン以降にライブラリが変わったか。
    ///   - ttl: キャッシュの有効期間。
    public static func needsRescan(scannedAt: Date?, isDirty: Bool, now: Date,
                                   ttl: TimeInterval) -> Bool {
        guard let scannedAt else { return true }        // キャッシュが無い
        if isDirty { return true }                      // 変更あり＝TTL 内でも古い
        return now.timeIntervalSince(scannedAt) > ttl   // 期限切れ
    }

    /// 索引・一覧の要求時に「現存を確かめる」必要があるか。
    /// 変更通知のあと、作り直しが終わるまでの間は true（削除済みを返さないため）。
    public static func needsExistenceCheck(indexBuiltAt: Date?, lastChangeAt: Date?) -> Bool {
        guard let indexBuiltAt else { return true }
        guard let lastChangeAt else { return false }
        return lastChangeAt > indexBuiltAt
    }

    /// 変更通知・スキャン完了のときに何をするか。
    ///
    /// ⚠️ 走行中に来た変更を「印を立てるだけ」で済ませると、**そのスキャンが終わった時点で
    /// 誰も印を見ない**。表示中のアルバムは次の `loadOrScan()`（＝画面を開き直すか TTL 切れ）
    /// まで古いままになる（レビュー指摘）。走行中の変更は完了時に拾い直す。
    public enum ScanAction: Equatable, Sendable {
        case scan            // いま走らせる
        case waitForRunning  // 走行中のスキャンの完了時に拾い直す
        case none            // やることなし
    }

    public static func scanAction(isDirty: Bool, isScanning: Bool) -> ScanAction {
        guard isDirty else { return .none }
        return isScanning ? .waitForRunning : .scan
    }
}
