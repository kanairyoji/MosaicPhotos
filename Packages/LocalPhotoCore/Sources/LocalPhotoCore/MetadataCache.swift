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

    func get(for id: String) -> PhotoMetadata? { store[id] }

    func bulkStore(_ batch: [PhotoMetadata]) {
        for m in batch { store[m.localIdentifier] = m }
    }
}
