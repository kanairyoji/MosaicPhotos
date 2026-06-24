#if canImport(UIKit)
import CryptoKit
import Foundation

/// キャッシュファイル名の生成（SHA256(path) ハッシュ + 拡張子）。状態を持たない純ロジックを
/// `DropboxCacheStore`（actor）から分離してテスト可能にする。ファイル名規約は既存キャッシュと互換。
enum DropboxCacheNaming {

    /// 種別ごとのキャッシュファイル名。サムネイルは常に `.jpg`、本体は元の拡張子（無ければ `bin`）。
    static func fileName(kind: CacheUsageEntry.CacheKind, path: String) -> String {
        let hashed = hash(path)
        switch kind {
        case .thumbnail:
            return "\(hashed).jpg"
        case .fullImage:
            let ext = (path as NSString).pathExtension
            let safeExt = ext.isEmpty ? "bin" : ext.lowercased()
            return "\(hashed).\(safeExt)"
        }
    }

    /// パスの SHA256 を 16 進文字列にする。
    static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
