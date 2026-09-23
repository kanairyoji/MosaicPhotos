import Foundation

/// **解析結果の公開**（ADR-222）の純ロジック: どのシャードを上げ直すか・どこから再開するか。
///
/// クラウドの写真は同じ Dropbox に接続した時点で相手からも見えるのに、解析（タグ・CLIP 埋め込み・
/// 顔・人物名・撮影日）は各自の端末でやり直しになっていた（6.8 万枚で数時間 × 人数）。
/// ここでは写真をコピーせず、**解析結果だけ**を `<root>/<端末>/Analysis/.mosaic-share/` へ置く。
///
/// ⚠️ 1 回の実行で全部は上げない。写真 1 枚あたり 1〜2KB（CLIP 埋め込みが主）なので、
/// 6.8 万枚なら 100〜200MB になる。**変わったシャードだけ**を、上限の数だけ順に上げる。
public enum AnalysisPublishPlanning {

    /// 1 回の実行で上げるシャードの上限（背景の回線を占有しない）。
    public static let defaultBudget = 8

    /// 上げるシャード 1 つ。
    public struct Upload: Equatable, Sendable {
        public let shard: String
        public let data: Data
        /// 上げ終わったら記録する指紋（次回はこれと比べて変化を判断する）。
        public let digest: String
        public init(shard: String, data: Data, digest: String) {
            self.shard = shard
            self.data = data
            self.digest = digest
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 上げるシャード（`budget` まで）。
        public var uploads: [Upload] = []
        /// 次回の再開位置（シャード名の昇順での位置）。
        public var nextCursor: Int = 0
        /// 変わっているが今回は上げなかったシャードの数（進み具合をログに出す）。
        public var remaining: Int = 0
        /// 公開対象から消えた（写真が Dropbox から消えた等）シャードのファイル名。
        public var stale: [String] = []
    }

    /// - Parameters:
    ///   - files: `ShareAnalysisData.shards(versions:entries:)` の結果（シャード名 → ファイル）。
    ///   - publishedDigests: 前回までに上げた指紋（シャード名 → 指紋）。
    ///   - cursor: 前回の続きの位置。
    /// - Returns: 上げるシャードと、次回の再開位置。
    public static func plan(files: [String: ShareAnalysisData.File],
                            publishedDigests: [String: String],
                            cursor: Int,
                            budget: Int = defaultBudget,
                            encode: (ShareAnalysisData.File) -> Data? = { encoded($0) })
        -> Plan {
        var plan = Plan()
        let shards = files.keys.sorted()
        guard !shards.isEmpty else {
            // 対象が 1 枚も無い（解析前・全部消えた）。記録に残っているシャードは消す対象。
            plan.stale = publishedDigests.keys.sorted().map { ShareAnalysisData.shardFileName($0) }
            return plan
        }
        // 変わったシャードだけを対象にする。指紋は中身（JSON のバイト列）から作る。
        var changed: [(shard: String, upload: Upload)] = []
        for shard in shards {
            guard let file = files[shard], let data = encode(file) else { continue }
            let digest = fingerprint(data)
            if publishedDigests[shard] == digest { continue }
            changed.append((shard, Upload(shard: shard, data: data, digest: digest)))
        }
        plan.stale = publishedDigests.keys.filter { files[$0] == nil }.sorted()
            .map { ShareAnalysisData.shardFileName($0) }
        guard !changed.isEmpty else {
            plan.nextCursor = 0
            return plan
        }
        // ⚠️ 続きの位置は**シャード名の昇順**で持つ（変わった数は回ごとに違うので、
        // 「何番目の変更」で持つと毎回違う場所を指す）。
        let start = changed.firstIndex { $0.shard > cursorShard(shards: shards, cursor: cursor) } ?? 0
        let ordered = Array(changed[start...] + changed[..<start])
        plan.uploads = ordered.prefix(budget).map(\.upload)
        plan.remaining = max(0, changed.count - plan.uploads.count)
        if let last = plan.uploads.last, let index = shards.firstIndex(of: last.shard) {
            plan.nextCursor = (index + 1) % shards.count
        }
        return plan
    }

    /// 続きの位置（索引）→ シャード名。範囲外は先頭の手前を指す空文字。
    static func cursorShard(shards: [String], cursor: Int) -> String {
        guard cursor > 0, cursor <= shards.count else { return "" }
        return shards[cursor - 1]
    }

    /// 公開する JSON を作る。
    ///
    /// ⚠️ **鍵を並べて書く**（`.sortedKeys`）。`Entry` の辞書は順序を持たないので、
    /// 既定のエンコーダだと同じ中身でも実行のたびにバイト列が変わる——指紋が毎回変わり、
    /// **何も変わっていなくても全シャードを上げ直す**（6.8 万枚なら毎晩 100〜200MB）。
    /// テストで実際に踏んだ（1 回目と 2 回目で同じ入力なのに差分が出た）。
    public static func encoded(_ file: ShareAnalysisData.File) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(file)
    }

    /// 中身の指紋（FNV-1a 64bit・16 進）。**内容が同じなら同じ**であればよく、暗号強度は要らない。
    public static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
