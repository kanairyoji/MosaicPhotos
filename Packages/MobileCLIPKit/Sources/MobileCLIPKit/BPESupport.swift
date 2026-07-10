import Foundation

/// CLIPTokenizer / GPT2Tokenizer が共有する byte-level BPE の足場。
/// bytes_to_unicode 写像・merges → ランク辞書の構築・最小ランクペア探索を一元化する。
///
/// `bpe()` 本体は共通化しない（アルゴリズムが実際に異なるため）:
/// - CLIP: 最小ランクペアを**最左の 1 箇所ずつ**マージし、語末に `</w>` マーカーを付ける。
/// - GPT2: 最小ランクペアの**全出現を一括**マージし、マーカー無し（空白は "Ġ" 前置）。
/// マージで新たに生まれた隣接ペアの方が低ランクの場合に両者の順序が食い違い得るため、
/// 統一するとトークン化結果が変わるリスクがある。
enum BPESupport {

    /// BPE の隣接ペア（マージ規則のキー）。
    struct Pair: Hashable {
        let a: String
        let b: String
    }

    /// GPT-2 / open_clip 共通の bytes_to_unicode 写像（byte → 可視 unicode 文字）を
    /// **割り当て順のまま**返す。制御文字・空白を避けつつ全 256 バイトへ一意な可視文字を
    /// 割り当てる。順序は CLIP の base vocab 構築（＝トークン ID）に効くので保存する。
    static func byteUnicodePairs() -> [(byte: UInt8, char: Character)] {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        return zip(bs, cs).map { (UInt8($0), Character(UnicodeScalar($1)!)) }
    }

    /// bytes_to_unicode の辞書形（byte → 可視 unicode 文字）。
    static func bytesToUnicode() -> [UInt8: Character] {
        var map: [UInt8: Character] = [:]
        for (b, ch) in byteUnicodePairs() { map[b] = ch }
        return map
    }

    /// merges 行（"a b" 形式）→ ペア列（並び順＝マージ優先度）。
    /// 2 要素でない行（空行・不正行）は読み飛ばす。
    static func parseMerges<S: StringProtocol>(_ lines: [S]) -> [Pair] {
        var merges: [Pair] = []
        merges.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.split(separator: " ")
            if parts.count == 2 { merges.append(Pair(a: String(parts[0]), b: String(parts[1]))) }
        }
        return merges
    }

    /// ペア列 → ランク辞書（配列位置＝ランク）。BPE はランクの**相対順**しか使わない。
    static func mergeRanks(_ merges: [Pair]) -> [Pair: Int] {
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (i, m) in merges.enumerated() { ranks[m] = i }
        return ranks
    }

    /// 隣接ペアのうち最小ランクのもの（同点は最左）と、その出現位置を返す。
    /// マージ可能なペアが無ければ nil。
    static func lowestRankedPair(in word: [String], ranks: [Pair: Int]) -> (pair: Pair, index: Int)? {
        guard word.count > 1 else { return nil }
        var best: (pair: Pair, rank: Int, index: Int)?
        for i in 0..<(word.count - 1) {
            let pair = Pair(a: word[i], b: word[i + 1])
            if let rank = ranks[pair], best == nil || rank < best!.rank {
                best = (pair, rank, i)
            }
        }
        return best.map { ($0.pair, $0.index) }
    }
}
