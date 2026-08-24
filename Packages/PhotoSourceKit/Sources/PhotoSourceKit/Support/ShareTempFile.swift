import Foundation

/// 共有用の一時ファイル置き場。元のファイル名を保つ（共有先での名前・形式判定）。
///
/// 直前の共有ファイルは次の共有の準備時に片付ける（原本サイズが大きいので溜めない）。
public enum ShareTempFile {

    /// 置き場（無ければ作る）。
    public static func directory() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// 書き出し先を用意する（同名の残骸があれば消す）。**逐次書き込み**の宛先に使う。
    public static func destination(filename: String) -> URL? {
        guard let dir = directory() else { return nil }
        let safe = filename.isEmpty ? "shared" : filename
        let url = dir.appendingPathComponent(safe)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// すでにメモリ上にあるデータ（クラウドのキャッシュ済み原本など）を書き出す。
    public static func write(_ data: Data, filename: String) -> URL? {
        guard let url = destination(filename: filename) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 置き場を空にする（前回の共有ファイルを残さない）。
    public static func clear() {
        guard let dir = directory(),
              let entries = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                         includingPropertiesForKeys: nil)
        else { return }
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }
}
