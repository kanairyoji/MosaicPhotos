import Foundation

/// 共有用に原本を一時ファイルへ書き出す。元のファイル名を保つ（共有先での名前・形式判定）。
enum ShareTempFile {
    static func write(_ original: SharedOriginal) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(original.filename)
        do {
            try original.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
