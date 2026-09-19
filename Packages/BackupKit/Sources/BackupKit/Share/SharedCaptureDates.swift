import Foundation
import MosaicSupport

/// **受け取った共有写真の撮影日**（ADR-199・受信側だけが持つ小さな表）。
///
/// ## なぜ要るか
/// 受信側が共有フォルダの写真について知っている日付は、Dropbox が返す
/// `time_taken ?? client_modified` だけ。共有コピーは `copy_batch_v2`（サーバーサイドコピー）で
/// 作られるので EXIF 由来の `time_taken` が付かないことが多く、日付は「提供者が反映した時刻」に
/// 落ちる——つまり**アップロード順**になる（実フィードバック「共有フォルダの表示が撮影時間順でない」）。
///
/// 自分のバックアップ副本には同じ問題への対処が既にある（ADR-128 追補）。ただしその対処は
/// **バックアップ台帳のパス**を引くので、家族フォルダ配下のパスは 1 件も当たらない。
/// 受信側には台帳が無く、撮影日を復元できる場所は解析データ（`ShareAnalysisData.Entry.d`）しかない。
/// ここはその値を置いておく場所で、表示側は既存の撮影日上書き（`BackupCopyInfo.captureDate`）に
/// 合流させて使う——**表示の仕組みは 1 つのまま**にする。
///
/// ## 置き場所
/// `.applicationSupportDirectory`（`PendingMetadataStore` と同じ）。Caches だと OS に消されて
/// 並び順が黙って壊れ、解析データの rev は「取り込み済み」のままなので**再取得されない**。
public struct SharedCaptureDateStore: Sendable {

    /// 表の上限。家族フォルダの写真枚数ぶんなので通常は数百〜数千件だが、
    /// 壊れた/巨大な入力で無制限に育てない（1 件あたり約 90 バイト ≒ 上限 1.8MB）。
    public static let maxEntries = 20_000

    private let url: URL

    public init(filename: String = "MosaicPhotos/SharedCaptureDates.json") {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent(filename)
    }

    /// Dropbox パス（小文字）→ 撮影日。表示側が引く形そのまま。
    public func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues { Self.date(from: $0) }
    }

    /// 撮影日を記録する。`keeping` を渡すと、そこに無いパスの記録は捨てる
    /// （家族フォルダから消えた写真の記録を残さない）。
    ///
    /// - Returns: 保存後の表（呼び出し側がそのまま表示へ渡せる）。
    @discardableResult
    public func record(_ dates: [String: Date], keeping: Set<String>? = nil) -> [String: Date] {
        let merged = Self.merged(existing: load(), adding: dates, keeping: keeping)
        save(merged)
        return merged
    }

    func save(_ dates: [String: Date]) {
        let raw = dates.mapValues(\.timeIntervalSince1970)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 純ロジック（テスト対象）

    /// 既存の表へ新しい撮影日を重ね、`keeping` に残っているパスだけを返す。
    ///
    /// - 新しい値が**勝つ**（提供者が撮影日を直したら追従する）。
    /// - `keeping` が nil なら掃除しない（一覧が取れなかった回に全部消さないため）。
    /// - 上限を超えたら**新しい撮影日から**残す（最近の写真ほど見られる）。
    public static func merged(existing: [String: Date],
                              adding: [String: Date],
                              keeping: Set<String>?) -> [String: Date] {
        var out = existing
        for (path, date) in adding { out[path.lowercased()] = date }
        if let keeping {
            let lower = Set(keeping.map { $0.lowercased() })
            out = out.filter { lower.contains($0.key) }
        }
        guard out.count > maxEntries else { return out }
        let kept = out.sorted { $0.value > $1.value }.prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// epoch 秒 → Date。NaN・非現実的な値は捨てる（解析データ側と同じ範囲）。
    /// ⚠️ ここを素通しにすると、並べ替えの strict weak ordering が壊れる。
    static func date(from epoch: Double) -> Date? {
        guard epoch.isFinite, ShareAnalysisData.plausibleEpochRange.contains(epoch) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
