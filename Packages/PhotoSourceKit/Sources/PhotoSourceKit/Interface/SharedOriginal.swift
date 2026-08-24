import Foundation

/// 共有に渡す原本。**一時ファイルへ書き出し済み**で、`UIActivityViewController` へ URL として渡す。
///
/// ⚠️ `Data` ではなくファイルで受け渡す。RAW / ProRAW / 高解像度では原本サイズがそのまま
/// メモリのピークになり、さらに一時ファイルへ書き戻すと二重に確保する（レビュー指摘）。
/// 供給側（ストア）が**逐次書き込み**でファイルを作り、こちらは URL だけ持つ。
public struct SharedOriginal: Sendable {
    public let fileURL: URL
    /// 元のファイル名（拡張子込み）。共有先での名前・形式判定に使われる。
    public var filename: String { fileURL.lastPathComponent }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
}
