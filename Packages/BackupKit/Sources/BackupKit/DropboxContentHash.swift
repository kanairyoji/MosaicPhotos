import CryptoKit
import Foundation

/// Dropbox の content_hash アルゴリズム（純関数・ADR-40）。
/// データを 4MB ブロックに分割し、各ブロックの SHA-256 ダイジェストを連結して
/// もう一度 SHA-256 → 小文字 hex。Dropbox API が返す `content_hash` と一致する。
/// https://www.dropbox.com/developers/reference/content-hash
///
/// 用途（アップロード確実性とオフロード安全性の土台）:
/// - アップロード直後: `files/upload` 応答の content_hash と照合して初めて「済み」記録にする
///   （HTTP 200 でも中身が壊れていた/途切れていたケースを検出）。
/// - オフロード直前: 端末の現データから再計算し、Dropbox 側 metadata と照合
///   （「今この瞬間、同一バイト列がクラウドに実在する」ことを削除の前提条件にする）。
enum DropboxContentHash {

    static let blockSize = 4 * 1024 * 1024

    /// content_hash を計算する。`blockSize` はテスト用に注入可能（本番は既定の 4MB）。
    static func hash(of data: Data, blockSize: Int = DropboxContentHash.blockSize) -> String {
        var blockDigests = Data()
        if data.isEmpty {
            blockDigests.append(contentsOf: SHA256.hash(data: Data()))
        } else {
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: blockSize, limitedBy: data.endIndex) ?? data.endIndex
                blockDigests.append(contentsOf: SHA256.hash(data: data[offset..<end]))
                offset = end
            }
        }
        return SHA256.hash(data: blockDigests).map { String(format: "%02x", $0) }.joined()
    }
}
