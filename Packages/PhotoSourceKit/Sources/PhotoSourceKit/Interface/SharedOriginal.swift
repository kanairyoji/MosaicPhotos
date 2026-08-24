import Foundation

/// 共有に渡す原本。ファイルへ書き出して `UIActivityViewController` に URL として渡す。
public struct SharedOriginal: Sendable {
    public let data: Data
    /// 元のファイル名（拡張子込み）。共有先での名前・形式判定に使われる。
    public let filename: String

    public init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }
}
