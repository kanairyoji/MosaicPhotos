import Foundation
import MosaicSupport
import SwiftData

/// **何度やっても画像が取れない写真を、候補から外す**（ADR-243・実機ログ diagnostics-101）。
///
/// ⚠️ 判定の純ロジックは `ScanAttemptPolicy`（下）に出してある——「何回で諦めるか」「いつ数えるか」を
/// 実時間や DB 無しで固定できるようにするため。実機で 6 時間ぶん同じ行が並んでから気づいた種類の
/// 不具合なので、**時間ではなく規則をテストする**。
extension FaceStore {

    /// これ以上は候補に入れない失敗回数。
    ///
    /// ⚠️ 5 回＋**1 時間間隔**＝最短でも 5 時間・5 つの別の窓で失敗しないと外れない。
    /// 譲り／回線での失敗は 1 つの窓で何千枚も巻き込むが、窓を跨いでは続かないので巻き込まれない。
    static let maxScanLoadFailures = 5
    /// 同じ写真の失敗を数え直すまでの間隔（1 つの窓で何度も数えない）。
    static let scanFailureCooldown: TimeInterval = 3600

    /// もう候補に入れない写真（失敗が上限に達したもの）。
    ///
    /// ⚠️ **読めなかったときは空を返さない**（ADR-242）。ここで `?? []` にすると、fetch が失敗した
    /// 瞬間に「外すものは無い」と読んで**永久ループへ戻る**——害は小さいが、同じ形は書かない。
    func unreadableRefKeys() -> Set<String> {
        let limit = Self.maxScanLoadFailures
        let d = FetchDescriptor<FaceScanAttempt>(predicate: #Predicate { $0.failures >= limit })
        guard let rows = countedFetchOptional(d) else {
            Self.log.error("faces: unreadableRefKeys — fetch failed（今回は外さない）")
            return []
        }
        return Set(rows.map(\.refKey))
    }

    /// 画像が取れなかったことを数える。
    /// - Returns: この呼び出しで**上限に達した**refKey（記録に残す用）。
    @discardableResult
    func recordScanLoadFailures(_ refKeys: [String], now: Date = Date()) -> [String] {
        guard !refKeys.isEmpty else { return [] }
        var exhausted: [String] = []
        for refKey in refKeys {
            let key = refKey
            var d = FetchDescriptor<FaceScanAttempt>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            let existing = countedFetchOptional(d)?.first
            guard let row = existing else {
                modelContext.insert(FaceScanAttempt(refKey: refKey, failures: 1, lastFailureAt: now))
                continue
            }
            // ⚠️ 同じ窓で何度も数えない（間隔が空いていなければ何もしない）。
            guard ScanAttemptPolicy.countsAgain(lastFailureAt: row.lastFailureAt, now: now,
                                                cooldown: Self.scanFailureCooldown) else { continue }
            row.failures += 1
            row.lastFailureAt = now
            if row.failures == Self.maxScanLoadFailures { exhausted.append(refKey) }
        }
        try? modelContext.save()
        return exhausted
    }

    /// 取れたので忘れる（一時的な失敗を溜め込まない）。
    func clearScanLoadFailures(_ refKeys: [String]) {
        guard !refKeys.isEmpty else { return }
        // ⚠️ `Set` を `#Predicate` に入れない（SwiftData の述語変換で落ちる＝実際に signal 11）。
        // 既存の同型（`FaceStore+Edit` の `chunk.contains($0.faceID)`）と同じく **Array** を渡す。
        let keys = Array(Set(refKeys))
        let d = FetchDescriptor<FaceScanAttempt>(predicate: #Predicate { keys.contains($0.refKey) })
        guard let rows = countedFetchOptional(d), !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
    }

    /// 全部忘れる（再スキャン・パイプライン版の更新・手動の「もう一度解析」）。
    /// ⚠️ **忘れる経路をセットで用意する**のが ADR-82 の決まり。記録だけ足して忘れ方が無いと、
    /// 一度こけた写真が版を上げても戻ってこない。
    func resetScanLoadFailures() {
        try? modelContext.delete(model: FaceScanAttempt.self)
        try? modelContext.save()
    }

    /// クラウド分だけ忘れる（`resetCloudScans` と対にする）。
    func resetCloudScanLoadFailures() {
        guard let rows = countedFetchOptional(FetchDescriptor<FaceScanAttempt>(
            predicate: #Predicate { $0.refKey.starts(with: "C-") })) else { return }
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
    }

    /// 診断用: (記録のある写真, 上限に達した写真) の数。
    func scanLoadFailureCounts() -> (tracked: Int, exhausted: Int) {
        let limit = Self.maxScanLoadFailures
        let tracked = (try? modelContext.fetchCount(FetchDescriptor<FaceScanAttempt>())) ?? 0
        let exhausted = (try? modelContext.fetchCount(FetchDescriptor<FaceScanAttempt>(
            predicate: #Predicate { $0.failures >= limit }))) ?? 0
        return (tracked, exhausted)
    }
}

/// 「いつ数え直すか」の純ロジック（ADR-243）。
///
/// ⚠️ 実時間で試すテストは書かない（ADR-241）。時計を引数にして規則だけを固定する。
public enum ScanAttemptPolicy {

    /// 前回から `cooldown` 以上経っていれば数え直す。
    /// ⚠️ `>=` にする（ちょうど境界のときに数えないと、時計の粒度で永久に数えられない写真が出る）。
    public static func countsAgain(lastFailureAt: Date, now: Date, cooldown: TimeInterval) -> Bool {
        now.timeIntervalSince(lastFailureAt) >= cooldown
    }

    /// 上限に達したか（＝もう候補に入れない）。
    public static func isExhausted(failures: Int, limit: Int) -> Bool { failures >= limit }
}
