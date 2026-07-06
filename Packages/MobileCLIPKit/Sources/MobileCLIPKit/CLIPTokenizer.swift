import Foundation

/// CLIP / MobileCLIP のテキスト用 BPE トークナイザ（open_clip の SimpleTokenizer 互換）。
/// `bpe_simple_vocab_16e6.txt`（バンドル同梱）を読み、文字列 → トークン ID 列（長さ 77）へ変換する。
/// テキストエンコーダ（Core ML）の入力に渡す。
/// スレッド安全：唯一の可変状態（BPE キャッシュ）はロックで保護する（検索の対比採点＝detached、
/// 表示ラベラの概念一括構築＝nonisolated、増分評価＝MainActor から**並行に**呼ばれる）。
final class CLIPTokenizer: @unchecked Sendable {
    /// 同梱語彙から一度だけ構築する共有インスタンス（語彙が無ければ nil）。
    static let shared = CLIPTokenizer()

    private let encoder: [String: Int]
    private let bpeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: String]
    private let bosToken: Int
    private let eosToken: Int
    private let contextLength: Int
    private let cacheLock = NSLock()
    private var cache: [String: String] = ["<|startoftext|>": "<|startoftext|>",
                                            "<|endoftext|>": "<|endoftext|>"]

    private struct Pair: Hashable { let a: String; let b: String }

    /// バンドルの語彙ファイルから初期化。見つからない/壊れている場合は nil。
    init?(contextLength: Int = 77) {
        guard let url = Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.contextLength = contextLength

        // byte → unicode 文字（open_clip bytes_to_unicode）
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var byteEnc: [UInt8: String] = [:]
        for (b, c) in zip(bs, cs) {
            byteEnc[UInt8(b)] = String(UnicodeScalar(c)!)
        }
        self.byteEncoder = byteEnc

        // merges = 行[1 ..< 49152-256-2+1] = 行[1 ..< 48895]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mergeLines = lines.count > 1 ? Array(lines[1..<min(lines.count, 48895)]) : []
        var merges: [Pair] = []
        merges.reserveCapacity(mergeLines.count)
        for line in mergeLines {
            let parts = line.split(separator: " ")
            if parts.count == 2 { merges.append(Pair(a: String(parts[0]), b: String(parts[1]))) }
        }

        // vocab 構築
        var vocab = cs.map { String(UnicodeScalar($0)!) }          // base 256
        vocab += vocab.map { $0 + "</w>" }                          // +256
        for m in merges { vocab.append(m.a + m.b) }                 // + merges
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        var enc: [String: Int] = [:]
        enc.reserveCapacity(vocab.count)
        for (i, tok) in vocab.enumerated() { enc[tok] = i }
        self.encoder = enc
        self.bosToken = enc["<|startoftext|>"] ?? 49406
        self.eosToken = enc["<|endoftext|>"] ?? 49407

        var ranks: [Pair: Int] = [:]
        for (i, m) in merges.enumerated() { ranks[m] = i }
        self.bpeRanks = ranks
    }

    /// 文字列 → 長さ `contextLength` のトークン ID（Int32）。BOS/EOS 付与、0 パディング、末尾切り詰め。
    func encode(_ text: String) -> [Int32] {
        var ids: [Int] = [bosToken]
        for token in tokenize(text) {
            for piece in bpe(token).split(separator: " ") {
                if let id = encoder[String(piece)] { ids.append(id) }
            }
        }
        ids.append(eosToken)

        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
            ids[contextLength - 1] = eosToken
        }
        var result = ids.map { Int32($0) }
        if result.count < contextLength {
            result += Array(repeating: 0, count: contextLength - result.count)
        }
        return result
    }

    // MARK: - Private

    /// open_clip の前処理 + 正規表現分割。
    private func tokenize(_ text: String) -> [String] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|\\p{L}+|\\p{N}|[^\\s\\p{L}\\p{N}]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = cleaned as NSString
        let matches = re.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }.filter { !$0.isEmpty }
    }

    /// 1 トークンを byte-encode してから BPE マージを適用し、サブワードを空白区切りで返す。
    private func bpe(_ token: String) -> String {
        // ⚠️ 共有シングルトンのため cache はロック必須。無防備な並行書き込みで Dictionary の
        // 内部構造が壊れ「NSTaggedPointerString count: unrecognized selector」等でクラッシュした（実障害）。
        // 計算自体はロック外（重複計算は無害・結果は同一）。
        cacheLock.lock()
        let cached = cache[token]
        cacheLock.unlock()
        if let cached { return cached }

        // byte-level エンコード（UTF-8 各バイト → unicode 文字）
        var word = Array(token.utf8).compactMap { byteEncoder[$0] }
        guard !word.isEmpty else { return token }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            // 最小ランクの隣接ペアを探す
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = bpeRanks[Pair(a: word[i], b: word[i + 1])] {
                    if best == nil || r < best!.rank { best = (r, i) }
                }
            }
            guard let (_, idx) = best else { break }
            word[idx] = word[idx] + word[idx + 1]
            word.remove(at: idx + 1)
        }

        let result = word.joined(separator: " ")
        cacheLock.lock()
        cache[token] = result
        cacheLock.unlock()
        return result
    }
}
