import Foundation

/// **軽い表（パス → hash・撮影日）をディスクに控える**（ADR-258・ADR-229 の 2 例目）。
///
/// ⚠️ なぜ要るか（実機ログ diagnostics-105）
/// 表は**作り直せる**のでメモリにしか持っていなかった。おかげで**毎起動 1 回**
/// 10.8 万行を歩き直していた——`cache.buildItemIndex` が **9.0 秒**、しかも
/// `DropboxCacheStore`（actor）は**その間ずっと塞がる**のでサムネ取得も待たされる。
/// ADR-229 が「作り直せる表はキー付きでディスクへ」と決めたのに、ここは適用されていなかった。
///
/// ## 形式（自前のバイナリ）
/// JSON / plist だと 10.8 万件のデコードがそれ自体で秒単位になり、置き換える意味が薄れる。
/// 固定長の前置きだけの素直な形にする:
/// ```
/// "MXIX" | UInt16 formatVersion | UInt64 contentVersion | UInt32 count
/// 以下 count 回: UInt16 pathLen | path(UTF8) | UInt8 hashLen | hash(UTF8)
///                | Float64 captureDate（NaN＝無し） | UInt8 probed
/// ```
/// ⚠️ `path` は表示にも使う**元の大文字小文字**を保つ（キーは呼び出し側が小文字化する）。
enum DropboxItemIndexSnapshot {

    /// 形式を変えたら**上げる**（上げると古い控えは読まずに作り直す）。
    static let formatVersion: UInt16 = 1
    static let magic = Array("MXIX".utf8)

    struct Row: Equatable, Sendable {
        var path: String
        var hash: String?
        var captureDate: Date?
        var probed: Bool
    }

    /// 控えの中身。`contentVersion` が**鍵**——これが台帳の現在値と一致しなければ使わない。
    struct Payload: Equatable, Sendable {
        var contentVersion: UInt64
        var rows: [Row]
    }

    // MARK: - 書き出し

    /// ⚠️⚠️ 桁に収まらない行が 1 つでもあれば**空を返す**（＝控えを作らない）。
    /// 以前は `continue` で**その行だけ飛ばして**いたが、前置きの `count` は
    /// `rows.count` のまま書いてあるので**件数が合わない**。しかも hash の判定は
    /// path を書いた**後**なので、**半端な行がファイルに残る**。
    /// 読み側は厳格（件数一致＋余り無し）なので実害は出ないが、
    /// 「万一超えたら控えない」とコメントが言っている振る舞いと**コードが違っていた**
    /// ——`guard` の `continue` は「1 行だけ無かったことにする」であって「控えない」ではない。
    /// Dropbox のパスは 1,000 文字未満・content_hash は 64 文字なので実際には起きない。
    static func encode(_ payload: Payload) -> Data {
        // 先に全部見る（書きながら諦めると、半端なものが残る）。
        for row in payload.rows {
            guard row.path.utf8.count <= Int(UInt16.max),
                  (row.hash ?? "").utf8.count <= Int(UInt8.max) else { return Data() }
        }
        var out = Data()
        out.reserveCapacity(payload.rows.count * 96 + 16)
        out.append(contentsOf: magic)
        appendLE(&out, formatVersion)
        appendLE(&out, payload.contentVersion)
        appendLE(&out, UInt32(payload.rows.count))
        for row in payload.rows {
            let path = Array(row.path.utf8)
            appendLE(&out, UInt16(path.count))
            out.append(contentsOf: path)
            let hash = Array((row.hash ?? "").utf8)
            appendLE(&out, UInt8(hash.count))
            out.append(contentsOf: hash)
            // ⚠️ 「無し」は NaN で表す（0 は 1970-01-01 という**実在する日付**）。
            appendLE(&out, (row.captureDate?.timeIntervalSince1970 ?? Double.nan).bitPattern)
            appendLE(&out, UInt8(row.probed ? 1 : 0))
        }
        return out
    }

    // MARK: - 読み込み

    /// ⚠️⚠️ **壊れていたら nil**（＝控えが無いのと同じ扱い）。
    /// 途中まで読めた分を返すと、**欠けた表を完成品として使う**ことになる
    /// ——`buildItemIndex` が同じ事故で「公開が一部の写真だけになる」を起こしかけた
    /// （そちらのコメント参照）。ここでも途中結果は返さない。
    static func decode(_ data: Data) -> Payload? {
        var r = Reader(data)
        guard let head = r.bytes(magic.count), Array(head) == magic,
              let version: UInt16 = r.read(), version == formatVersion,
              let contentVersion: UInt64 = r.read(),
              let count: UInt32 = r.read() else { return nil }
        var rows: [Row] = []
        rows.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let pathLen: UInt16 = r.read(),
                  let pathBytes = r.bytes(Int(pathLen)),
                  let path = String(bytes: pathBytes, encoding: .utf8),
                  let hashLen: UInt8 = r.read(),
                  let hashBytes = r.bytes(Int(hashLen)),
                  let hash = String(bytes: hashBytes, encoding: .utf8),
                  let dateBits: UInt64 = r.read(),
                  let probed: UInt8 = r.read() else { return nil }
            let seconds = Double(bitPattern: dateBits)
            rows.append(Row(path: path,
                            hash: hash.isEmpty ? nil : hash,
                            captureDate: seconds.isNaN ? nil : Date(timeIntervalSince1970: seconds),
                            probed: probed == 1))
        }
        // ⚠️ 余りがあるのは形式の読み違い（＝信用できない）。
        guard r.isAtEnd else { return nil }
        return Payload(contentVersion: contentVersion, rows: rows)
    }

    // MARK: - 下請け

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int
        init(_ data: Data) { self.data = data; self.offset = 0 }
        var isAtEnd: Bool { offset == data.count }

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }

        mutating func read<T: FixedWidthInteger>() -> T? {
            guard let slice = bytes(MemoryLayout<T>.size) else { return nil }
            return T(littleEndian: slice.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }
    }
}
