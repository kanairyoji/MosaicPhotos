#if canImport(UIKit)
import ImageCacheKit
import UIKit

/// Two-level thumbnail cache: in-memory (`MemoryImageCache`) + on-disk (`DiskImageStore`),
/// with disk LRU eviction based on file modification date.
///
/// メモリ層・ディスク I/O は `ImageCacheKit` の共通プリミティブに委譲し、本型は
/// 「mtime ベース LRU + バイト上限管理」というローカル写真向けのポリシーだけを持つ。
/// All methods are actor-isolated for thread safety.
/// Read path: memory hit → disk hit (promotes to memory) → nil.
public actor ThumbnailCache {

    public static let shared = ThumbnailCache()

    private let memory: MemoryImageCache
    private let disk: DiskImageStore
    private var maxDiskBytes: Int
    private var diskUsage = 0

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("LocalPhotoKit/thumbnails", isDirectory: true)
        disk = DiskImageStore(directory: directory)

        let memMB = UserDefaults.standard.integer(forKey: CacheSettingsKeys.memoryLimitMB)
        let diskMB = UserDefaults.standard.integer(forKey: CacheSettingsKeys.diskLimitMB)
        memory = MemoryImageCache(totalCostLimit: (memMB > 0 ? memMB : 100) * 1024 * 1024)
        maxDiskBytes = (diskMB > 0 ? diskMB : 500) * 1024 * 1024

        diskUsage = disk.totalUsage()
    }

    // MARK: - Configuration

    public func updateMemoryLimit(_ bytes: Int) async {
        memory.setTotalCostLimit(bytes)
    }

    public func updateDiskLimit(_ bytes: Int) async {
        maxDiskBytes = bytes
        if diskUsage > maxDiskBytes { evictDisk() }
    }

    public func currentDiskUsage() async -> Int { diskUsage }

    public func clear() async {
        memory.removeAll()
        disk.clear()
        diskUsage = 0
    }

    // MARK: - Public API

    func get(_ key: String) async -> UIImage? {
        if let img = memory.image(forKey: key) { return img }

        let name = fileName(for: key)
        guard let data = disk.data(forName: name),
              let decoded = UIImage(data: data) else { return nil }
        // actor 内（オフメイン）で強制デコードし、描画時のメインスレッドデコードを回避。
        let img = decoded.preparingForDisplay() ?? decoded

        memory.insert(img, forKey: key, cost: data.count)
        disk.touch(name: name)   // refresh LRU timestamp on disk hit
        return img
    }

    func set(_ image: UIImage, for key: String) async {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        // actor 内（オフメイン）で強制デコードしてからメモリ層へ。
        let prepared = image.preparingForDisplay() ?? image
        memory.insert(prepared, forKey: key, cost: data.count)

        let name = fileName(for: key)
        let oldSize = disk.fileSize(forName: name)
        disk.write(data, name: name)
        diskUsage = diskUsage - oldSize + data.count

        if diskUsage > maxDiskBytes { evictDisk() }
    }

    // MARK: - Private

    /// ファイル名スキームは従来どおり（既存キャッシュとの互換を維持）。
    private func fileName(for key: String) -> String {
        let safe = key
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "_")
        return safe + ".jpg"
    }

    /// 更新日時（mtime）の古い順に、使用量が上限の 80% を下回るまで破棄する。
    private func evictDisk() {
        let entries = disk.entries().sorted { $0.modified < $1.modified }
        let target = maxDiskBytes * 4 / 5
        for entry in entries {
            guard diskUsage > target else { break }
            disk.removeFile(at: entry.url)
            diskUsage -= entry.size
        }
    }
}
#endif
