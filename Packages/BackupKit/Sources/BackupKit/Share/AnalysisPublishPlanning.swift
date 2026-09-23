import Foundation

/// **解析結果の公開**（ADR-222）の純ロジック: この回どのシャードを見るか・どこから再開するか。
///
/// クラウドの写真は同じ Dropbox に接続した時点で相手からも見えるのに、解析（タグ・CLIP 埋め込み・
/// 顔・人物名・撮影日）は各自の端末でやり直しになっていた（6.8 万枚で数時間 × 人数）。
/// ここでは写真をコピーせず、**解析結果だけ**を `<root>/<端末>/Analysis/.mosaic-share/` へ置く。
///
/// ## ⚠️ 1 回で全部を組み立てない（実機ログ diagnostics-85）
/// 最初は「全シャードを作る → 全部を JSON にして指紋を比べる → 変わったものを budget 個上げる」
/// にしていた。6.8 万枚ぶんの解析（base64 の CLIP 埋め込みが主）を**一度に実体化**したうえ、
/// **256 シャード全部の JSON を同時に持つ**ので、実機のフットプリントが **637MB** まで上がった
/// ——背景の窓でこれをやると jetsam でアプリごと落ちる（`PhotoEmbedding` を inline に持っていた
/// 頃の起動クラッシュと同じ形・ADR-119/122）。解析の取得も 9.7 万枚ぶん（2,000 枚 × 49 回）で
/// 1 回 67 秒かかっていた。
///
/// いまは**この回に見るシャードぶんだけ**を組み立てる（写真にして数百枚）。1 巡の総量は変わらず、
/// ピークが 1/32 になる。代わりに「変わったシャード」に気づくのは巡ってきたときなので、
/// 全体を見終わるのに `256 / budget` 回の窓がかかる（30 分間隔なら半日）——解析は後から効くもので、
/// 半日遅れても困らない。
public enum AnalysisPublishPlanning {

    /// 1 回の実行で見るシャードの数（背景の回線とメモリを占有しない）。
    public static let defaultBudget = 8

    /// この回に見るシャードと、次回の再開位置。
    public struct Window: Equatable, Sendable {
        /// この回に組み立てて指紋を比べるシャード（シャード名の昇順・続きから一巡）。
        public var shards: [String] = []
        /// 次回の再開位置（シャード名の昇順での位置）。
        public var nextCursor = 0
        /// この回に見なかったシャードの数（進み具合をログに出す）。
        public var remaining = 0
        /// 公開対象から消えた（写真が Dropbox から消えた等）シャードのファイル名。
        public var stale: [String] = []
    }

    /// - Parameters:
    ///   - presentShards: いま手元にある写真の content_hash から決まるシャード名の集合。
    ///   - publishedDigests: 前回までに上げた指紋（シャード名 → 指紋）。消えたシャードの検出に使う。
    ///   - cursor: 前回の続きの位置。
    public static func window(presentShards: Set<String>,
                              publishedDigests: [String: String],
                              cursor: Int,
                              budget: Int = defaultBudget) -> Window {
        var window = Window()
        // 対象から消えたシャード（写真が消えた・よそへ移った）は消す。
        window.stale = publishedDigests.keys.filter { !presentShards.contains($0) }.sorted()
            .map { ShareAnalysisData.shardFileName($0) }
        let all = presentShards.sorted()
        guard !all.isEmpty, budget > 0 else { return window }
        // ⚠️ 続きの位置は**シャード名**で持つ（写真の増減で集合が変わるので、
        // 「何番目」だけでは同じ場所を指さない）。
        let start = all.firstIndex { $0 > cursorShard(shards: all, cursor: cursor) } ?? 0
        let ordered = Array(all[start...] + all[..<start])
        window.shards = Array(ordered.prefix(budget))
        window.remaining = max(0, all.count - window.shards.count)
        if let last = window.shards.last, let index = all.firstIndex(of: last) {
            window.nextCursor = (index + 1) % all.count
        }
        return window
    }

    /// 続きの位置（索引）→ シャード名。範囲外は先頭の手前を指す空文字。
    static func cursorShard(shards: [String], cursor: Int) -> String {
        guard cursor > 0, cursor <= shards.count else { return "" }
        return shards[cursor - 1]
    }

    /// 公開する JSON を作る。
    ///
    /// ⚠️ **鍵を並べて書く**（`.sortedKeys`）。`Entry` の辞書は順序を持たないので、
    /// 既定のエンコーダだと同じ中身でもバイト列が変わる——指紋が毎回変わり、
    /// **何も変わっていなくても全シャードを上げ直す**（6.8 万枚なら毎晩 100〜200MB）。
    /// テストで実際に踏んだ。
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
