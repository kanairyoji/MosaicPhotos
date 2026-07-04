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
    /// アセットごとに「最後にメモリへ載せたキー（＝サイズ）」を覚える。ズーム直後の
    /// キャッシュミス時に別サイズを暫定表示するための軽量索引（メモリのみ・NSCache は列挙不可のため）。
    private var lastKeyByAsset: [String: String] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("LocalPhotoKit/thumbnails", isDirectory: true)
        disk = DiskImageStore(directory: directory)

        // memoryLimitMB は未設定(0)=「Auto」。Auto は端末 RAM に応じて自動算出する。
        let memMB = UserDefaults.standard.integer(forKey: CacheSettingsKeys.memoryLimitMB)
        let diskMB = UserDefaults.standard.integer(forKey: CacheSettingsKeys.diskLimitMB)
        // critical 圧迫でも全消去せず段階縮小に留める（サムネは小さく、再取得/再デコードの storm を避ける）。
        memory = MemoryImageCache(totalCostLimit: ThumbnailMemoryBudget.effectiveBytes(forSettingMB: memMB),
                                  purgeOnCritical: false)
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
        lastKeyByAsset.removeAll()
    }

    // MARK: - Public API

    /// デコード（JPEG 展開＋`preparingForDisplay`）の同時実行数制限。
    /// デコードを actor 内で行うと**全セルの読み込みが 1 本に直列化**され高速スクロールの
    /// スループットが律速される（Dropbox 側 `ThumbnailDecode` と同じ問題）。actor 外で
    /// 並列実行しつつ、無制限の並列による CPU 競合はセマフォで防ぐ。
    private static let decodeLimiter = AsyncSemaphore(
        value: max(6, ProcessInfo.processInfo.activeProcessorCount * 2))

    /// メモリ→ディスクの順で探す。ディスクヒット時のデコードは actor 外・並列（同時数制限つき）。
    nonisolated func get(_ key: String) async -> UIImage? {
        if let img = await memoryImage(forKey: key) { return img }

        guard let data = await diskData(forKey: key) else { return nil }
        await Self.decodeLimiter.acquire()
        let decoded = UIImage(data: data)
        // 強制デコード（オフメイン）。描画時のメインスレッドデコードを回避。
        let img = decoded.map { $0.preparingForDisplay() ?? $0 }
        await Self.decodeLimiter.release()
        guard let img else { return nil }
        await promote(img, forKey: key)
        return img
    }

    /// HQ サムネイルを保存する。JPEG エンコードは actor 外（並列・同時数制限つき）で行う。
    nonisolated func set(_ image: UIImage, for key: String) async {
        await Self.decodeLimiter.acquire()
        let prepared = image.preparingForDisplay() ?? image
        let data = image.jpegData(compressionQuality: 0.8)
        await Self.decodeLimiter.release()
        guard let data else { return }
        await store(prepared, data: data, forKey: key)
    }

    /// メモリ層のみの即答（デコード無し）。2段階サムネイルの最速パス。
    func memoryImage(forKey key: String) -> UIImage? {
        if let img = memory.image(forKey: key) {
            lastKeyByAsset[assetID(from: key)] = key
            return img
        }
        return nil
    }

    /// 同一アセットの**別サイズ**がメモリにあれば返す（ズーム直後の暫定表示用）。
    /// 目的サイズのキャッシュミス時に「まず何か見せる」ために使う（最終画質は後から差し替え）。
    func nearestMemoryImage(assetID: String) -> UIImage? {
        guard let key = lastKeyByAsset[assetID] else { return nil }
        return memory.image(forKey: key)
    }

    // MARK: - Actor-isolated primitives（I/O とメモリ層。重い CPU 処理は置かない）

    private func diskData(forKey key: String) -> Data? {
        let name = fileName(for: key)
        guard let data = disk.data(forName: name) else { return nil }
        disk.touch(name: name)   // refresh LRU timestamp on disk hit
        return data
    }

    private func promote(_ image: UIImage, forKey key: String) {
        // 実デコードサイズでコスト計上（JPEG バイトではなく）。totalCostLimit を正しく効かせる。
        memory.insertDecoded(image, forKey: key)
        lastKeyByAsset[assetID(from: key)] = key
    }

    private func store(_ image: UIImage, data: Data, forKey key: String) {
        memory.insertDecoded(image, forKey: key)
        lastKeyByAsset[assetID(from: key)] = key

        let name = fileName(for: key)
        let oldSize = disk.fileSize(forName: name)
        disk.write(data, name: name)
        diskUsage = diskUsage - oldSize + data.count

        if diskUsage > maxDiskBytes { evictDisk() }
    }

    /// キー（"localIdentifier:WxH"）からアセット ID 部分を取り出す（近似サイズ索引用）。
    private func assetID(from key: String) -> String {
        guard let idx = key.lastIndex(of: ":") else { return key }
        return String(key[..<idx])
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
