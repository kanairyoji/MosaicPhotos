import Foundation
import MosaicSupport

/// **受け取った共有写真の撮影日**（ADR-199・受信側だけが持つ小さな表）。
///
/// ## なぜ要るか
/// 受信側が共有フォルダの写真について知っている日付は、Dropbox が返す
/// `time_taken ?? client_modified` だけ。⚠️ Dropbox は **2019-12-02 以降、`list_folder` /
/// `list_folder/continue` / `get_thumbnail_batch` で `media_info` を返さない**
/// （`include_media_info` も無視される）ので、`time_taken` は**常に nil**。
/// 日付は `client_modified`＝「提供者が反映した時刻」に落ちる——つまり**アップロード順**になる
/// （実フィードバック「共有フォルダの表示が撮影時間順でない」）。
/// ※ コピーの作り方（サーバーサイドコピー）は無関係（レビュー 18 周目の訂正）。
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

    /// 表の上限。1 件あたり約 90 バイト ≒ 上限 4.5MB。
    /// ⚠️ 共有セット 1 つで 12,941 枚に達した実績があるので、2 セットで 2 万件を超える。
    /// 上限に当たると並びが崩れるので、現実的な枚数より十分上に取る（レビュー指摘）。
    public static let maxEntries = 50_000

    private let url: URL

    public init(filename: String = "MosaicPhotos/SharedCaptureDates.json") {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent(filename)
    }

    /// テスト用（往復と、書けない場所での挙動を確かめる）。
    /// `PendingMetadataStore` と同じ差し込み口の形に揃えてある。
    init(directory: URL, filename: String) {
        url = directory.appendingPathComponent(filename)
    }

    /// Dropbox パス（小文字）→ 撮影日。表示側が引く形そのまま。
    public func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues { Self.date(from: $0) }
    }

    /// 記録の結果。
    ///
    /// ⚠️ **「やり直す価値がある失敗」と「やり直しても同じ結果」を分ける**（レビュー指摘）。
    /// 分けないと、上限に当たって落ちた撮影日のせいでその解析データが永久に
    /// 「取り込み済み」にならず、毎回同じものを取り直す——しかも 1 回あたりの取得数には
    /// 上限があるので、その先のシャードが一つも取れなくなる（取り込み全体が止まる）。
    public struct Outcome: Sendable {
        /// 保存後の表（呼び出し側がそのまま表示へ渡せる）。
        public let table: [String: Date]
        /// ファイルへの保存そのものに失敗した。**やり直す価値がある**ので、
        /// この回の解析データは「取り込み済み」にしない。
        public let saveFailed: Bool
        /// 上限（または掃除）に当たって入らなかった受信ぶん（小文字）。
        ///
        /// ⚠️ ここで取り込みを止めてはいけない。止めると解析データが永久に取り込み済みに
        /// ならず、取得の上限を食い潰して全体が進まなくなる（レビュー 3 周目）。
        /// ⚠️ ただし「やり直しても同じ」とは限らない——掃除で表が縮めば明日は入り得る。
        /// それでも止めないのは、**止めた場合の害（取り込み全体の停止）が大きすぎる**から。
        public let droppedByCap: Set<String>
        /// 上限に当たって**既存の記録から押し出された**件数（レビュー指摘）。
        ///
        /// 押し出された写真の解析データは既に「取り込み済み」なので再取得されない
        /// ＝撮影日は戻らない。受信ぶんだけを見ていると 0 件と報告され、
        /// **静かに並びが壊れる**。数えて記録に残す。
        public let evictedExisting: Int
    }

    /// 撮影日を記録する。`keeping` を渡すと、そこに無いパスの記録は捨てる
    /// （家族フォルダから消えた写真の記録を残さない）。
    @discardableResult
    public func record(_ dates: [String: Date], keeping: Set<String>? = nil) -> Outcome {
        let existing = load()
        let merged = Self.merged(existing: existing, adding: dates, keeping: keeping)
        let saved = save(merged)
        // ⚠️ **書けなかった回は「落ちた」「押し出した」を数えない**（レビュー指摘）。
        // 数えると、実際にはディスク上で無傷の記録を「失われた」と診断ログに書いてしまう。
        // 取りこぼしを必ず残す方針なので、**嘘の取りこぼし**は抜けと同じくらい害になる。
        guard saved else {
            return Outcome(table: load(), saveFailed: true,
                           droppedByCap: [], evictedExisting: 0)
        }
        // 入らなかったものは**混ぜた結果**で判定する（ファイルを読み直さない）。
        var droppedByCap: Set<String> = []
        for (path, date) in dates where merged[path.lowercased()] != date {
            droppedByCap.insert(path.lowercased())
        }
        // 既存の記録が押し出された数（掃除で消えたぶんは除く＝上限が原因のものだけ）。
        let incoming = Set(dates.keys.map { $0.lowercased() })
        let lowerKeeping = keeping.map { Set($0.map { $0.lowercased() }) }
        let evictedByCap = existing.keys.filter { key in
            merged[key] == nil && !incoming.contains(key)
                && (lowerKeeping?.contains(key) ?? true)   // 掃除で消えたぶんは数えない
        }.count
        return Outcome(table: merged, saveFailed: false,
                       droppedByCap: droppedByCap, evictedExisting: evictedByCap)
    }

    /// - Returns: 書けたか。書けなければ呼び出し側が次回やり直す。
    @discardableResult
    func save(_ dates: [String: Date]) -> Bool {
        let raw = dates.mapValues(\.timeIntervalSince1970)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(raw) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            BackupLogger.error("SharedCaptureDateStore: save failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 純ロジック（テスト対象）

    /// 既存の表へ新しい撮影日を重ね、`keeping` に残っているパスだけを返す。
    ///
    /// - 新しい値が**勝つ**（提供者が撮影日を直したら追従する）。
    /// - `keeping` が nil なら掃除しない（一覧が取れなかった回に全部消さないため）。
    /// - 上限を超えたら**古い撮影日から**残す。
    ///
    /// ⚠️ 残す向きは「古い方」。**逆にしてはいけない**（レビュー指摘）。撮影日を落とした写真は
    /// Dropbox の日付＝提供者が反映した時刻（≒最近）にフォールバックするので、
    /// - 新しい写真を落とす → ずれは小さい（元々最近の写真）。
    /// - 古い写真を落とす → 何年も前の写真が列の**末尾＝最新側**へ飛ぶ。
    /// つまり古い写真ほど上書きの価値が高い。新しい方を残す実装は、元の不具合を
    /// 「古い写真だけ」に集中させて悪化させる。
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
        // 同着はパスで決定的に切る（実行ごとに残る顔ぶれが変わらないように）。
        let kept = out.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// epoch 秒 → Date。NaN・非現実的な値は捨てる（解析データ側と同じ範囲）。
    /// ⚠️ ここを素通しにすると、並べ替えの strict weak ordering が壊れる。
    static func date(from epoch: Double) -> Date? {
        guard epoch.isFinite, ShareAnalysisData.plausibleEpochRange.contains(epoch) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
