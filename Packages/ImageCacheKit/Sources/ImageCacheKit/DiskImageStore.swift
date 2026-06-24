import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 1 ディレクトリ配下のバイナリ画像をファイル名キーで読み書きする、ディスク I/O の共通
/// プリミティブ。`FileManager` を薄くラップするだけで、破棄ポリシー（LRU 等）は持たない。
///
/// 破棄ポリシーは利用側が決める：
/// - LocalPhotoKit の `ThumbnailCache` はファイルの更新日時（mtime）ベース LRU
/// - DropboxCore の `DropboxCacheStore` は SwiftData(`CacheUsageEntry`) ベース LRU
///
/// コア（Data / FileManager 操作・LRU 列挙）は Foundation のみで、macOS でもユニット
/// テスト可能。`UIImage` を返す便宜メソッドのみ `#if canImport(UIKit)` 拡張に分離する。
///
/// `FileManager` はスレッドセーフ、`directory` は不変のため `@unchecked Sendable`。
/// detached タスクからの書き込みにも安全に渡せる。
public final class DiskImageStore: @unchecked Sendable {
    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    public func fileURL(forName name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - Read

    public func data(forName name: String) -> Data? {
        try? Data(contentsOf: fileURL(forName: name))
    }

    public func fileSize(forName name: String) -> Int {
        (try? fileURL(forName: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - Write / delete

    /// データをアトミックに書き込む（ディレクトリは必要に応じて作成）。
    public func write(_ data: Data, name: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(forName: name), options: .atomic)
    }

    public func remove(name: String) {
        try? fileManager.removeItem(at: fileURL(forName: name))
    }

    public func removeFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// ディレクトリ内の全ファイルを削除する。
    public func clear() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents { try? fileManager.removeItem(at: url) }
    }

    /// disk hit 時に LRU タイムスタンプ（mtime）を更新する。
    public func touch(name: String, date: Date = Date()) {
        try? fileManager.setAttributes([.modificationDate: date],
                                       ofItemAtPath: fileURL(forName: name).path)
    }

    // MARK: - Enumeration (for LRU / usage)

    /// 1 ファイルのメタ情報（mtime ベース LRU に使用）。
    public struct Entry: Sendable {
        public let url: URL
        public let size: Int
        public let modified: Date
    }

    public func entries() -> [Entry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return [] }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { return nil }
            return Entry(url: url, size: size, modified: modified)
        }
    }

    /// ディレクトリ配下の合計バイト数。
    public func totalUsage() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }
}

#if canImport(UIKit)
/// `UIImage` を actor / Task 境界を越えて受け渡すための Sendable ラッパー。
/// `UIImage` は読み取りスレッドセーフだが `Sendable` 未適合のため、バックグラウンドで
/// デコードした画像をメインへ返す際に用いる。
public struct SendableUIImage: @unchecked Sendable {
    public let image: UIImage
    public init(_ image: UIImage) { self.image = image }
}

public extension DiskImageStore {
    /// ディスク上のバイナリを `UIImage` にデコードして返す（遅延デコード）。
    func image(forName name: String) -> UIImage? {
        guard let data = data(forName: name) else { return nil }
        return UIImage(data: data)
    }

    /// ディスク上のバイナリを読み込み、`preparingForDisplay()` で**即時（強制）デコード**して返す。
    /// 呼び出したスレッドでデコードが行われるため、バックグラウンドから呼ぶことでメイン
    /// スレッドの描画時デコードを回避する。
    func decodedImage(forName name: String) -> UIImage? {
        guard let data = data(forName: name), let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}
#endif
