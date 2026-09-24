import MosaicSupport
import Photos

/// Lightweight snapshot of a PHAsset's properties, cached in memory.
struct PhotoMetadata: Sendable {
    let localIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
}

/// In-memory store for pre-loaded PHAsset metadata, populated by MetadataPreloader.
actor MetadataCache {

    static let shared = MetadataCache()

    private var store: [String: PhotoMetadata] = [:]

    init() {
        // ⚠️ **圧迫で捨てられるようにする**（CLAUDE.md「メモリ圧迫対応は MemoryPressureMonitor に
        // 集約」）。この表は PHAsset から作り直せるのに、捨てる API すら無く、端末 1.8 万件ぶんが
        // プロセスの最後まで残っていた（常駐メモリの棚卸し）。
        _ = MemoryPressureMonitor.shared.register { [weak self] _ in
            Task { await self?.clear() }
        }
    }

    func get(for id: String) -> PhotoMetadata? { store[id] }

    func bulkStore(_ batch: [PhotoMetadata]) {
        for m in batch { store[m.localIdentifier] = m }
    }

    /// 捨てる（圧迫時・作り直せる）。
    func clear() {
        guard !store.isEmpty else { return }
        store.removeAll(keepingCapacity: false)
    }
}
