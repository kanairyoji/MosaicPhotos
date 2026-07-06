import Foundation

/// GPT2 系 byte-level BPE トークナイザ（SmolLM2 用）。
/// `vlm_vocab.json`（token→id）と `vlm_merges.txt`（マージ順）から構築する。
/// CLIPTokenizer と同じ byte→unicode 写像だが、`</w>` を使わず空白は "Ġ" 前置で表す点が異なる。
/// キャプションのデコード（id→文字列）と、固定英語プロンプトのエンコードに使う。
final class GPT2Tokenizer: @unchecked Sendable {

    private let encoder: [String: Int]
    private let decoder: [Int: String]
    private let bpeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: Character]
    private let byteDecoder: [Character: UInt8]
    /// 特殊トークン（<|im_start|>・<end_of_utterance> 等）。エンコード時に文字列一致で分離する。
    private let specialTokens: [String: Int]

    private struct Pair: Hashable { let a: String; let b: String }

    init?() {
        guard let vocabURL = Bundle.main.url(forResource: "vlm_vocab", withExtension: "json"),
              let mergesURL = Bundle.main.url(forResource: "vlm_merges", withExtension: "txt"),
              let configURL = Bundle.main.url(forResource: "vlm_config", withExtension: "json"),
              let vocabData = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int].self, from: vocabData),
              let mergesText = try? String(contentsOf: mergesURL, encoding: .utf8),
              let configData = try? Data(contentsOf: configURL),
              let configJSON = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else { return nil }

        var enc = vocab
        let added = (configJSON["addedTokens"] as? [String: Int]) ?? [:]
        for (token, id) in added { enc[token] = id }
        self.specialTokens = added
        self.encoder = enc
        self.decoder = Dictionary(uniqueKeysWithValues: enc.map { ($0.value, $0.key) })

        var ranks: [Pair: Int] = [:]
        for (i, line) in mergesText.split(separator: "\n").enumerated() {
            let parts = line.split(separator: " ")
            if parts.count == 2 { ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = i }
        }
        self.bpeRanks = ranks

        // byte → unicode（GPT2 bytes_to_unicode・CLIP と同一の写像）
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var byteEnc: [UInt8: Character] = [:]
        var byteDec: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) {
            let ch = Character(UnicodeScalar(c)!)
            byteEnc[UInt8(b)] = ch
            byteDec[ch] = UInt8(b)
        }
        self.byteEncoder = byteEnc
        self.byteDecoder = byteDec
    }

    // MARK: - Encode（固定英語プロンプト用）

    func encode(_ text: String) -> [Int] {
        // 特殊トークンを文字列一致で分離してから、通常テキストを BPE する。
        var ids: [Int] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            // 最も手前に現れる特殊トークンを探す。
            var earliest: (range: Range<Substring.Index>, id: Int)?
            for (token, id) in specialTokens {
                if let r = remaining.range(of: token) {
                    if earliest == nil || r.lowerBound < earliest!.range.lowerBound {
                        earliest = (r, id)
                    }
                }
            }
            if let (range, id) = earliest {
                ids.append(contentsOf: encodePlain(String(remaining[..<range.lowerBound])))
                ids.append(id)
                remaining = remaining[range.upperBound...]
            } else {
                ids.append(contentsOf: encodePlain(String(remaining)))
                break
            }
        }
        return ids
    }

    private static let pattern =
        #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#

    private func encodePlain(_ text: String) -> [Int] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: Self.pattern) else { return [] }
        let ns = text as NSString
        var ids: [Int] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let piece = ns.substring(with: m.range)
            let mapped = String(piece.utf8.compactMap { byteEncoder[$0] })
            for sub in bpe(mapped) {
                if let id = encoder[sub] { ids.append(id) }
            }
        }
        return ids
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard word.count > 1 else { return word }
        while true {
            var best: (pair: Pair, rank: Int)?
            for i in 0..<(word.count - 1) {
                let pair = Pair(a: word[i], b: word[i + 1])
                if let rank = bpeRanks[pair], best == nil || rank < best!.rank {
                    best = (pair, rank)
                }
            }
            guard let (pair, _) = best else { break }
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == pair.a, word[i + 1] == pair.b {
                    merged.append(pair.a + pair.b)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
            if word.count == 1 { break }
        }
        return word
    }

    // MARK: - Decode（生成キャプション用）

    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = decoder[id] else { continue }
            if specialTokens[token] != nil { continue }   // 特殊トークンは出力しない
            for ch in token {
                if let b = byteDecoder[ch] { bytes.append(b) }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
