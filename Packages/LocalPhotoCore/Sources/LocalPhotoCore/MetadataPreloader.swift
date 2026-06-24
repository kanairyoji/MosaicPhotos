import Photos

/// Preloads PHAsset metadata into MetadataCache in background chunks of 50.
///
/// Processing is interruptible: visible-load tasks cancelling the preloader
/// or explicit `cancel()` stops the loop promptly via Task.isCancelled checks.
actor MetadataPreloader {

    private var currentTask: Task<Void, Never>?
    private let chunkSize = 50

    /// Start (or restart) preloading. Cancels any in-flight preload first.
    func start(assets: [PHAsset]) {
        currentTask?.cancel()
        currentTask = Task(priority: .utility) { [weak self] in
            await self?.preload(assets: assets)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private

    private func preload(assets: [PHAsset]) async {
        var offset = 0
        while offset < assets.count {
            guard !Task.isCancelled else { return }

            let end = min(offset + chunkSize, assets.count)
            let batch = assets[offset..<end].map { asset in
                PhotoMetadata(
                    localIdentifier: asset.localIdentifier,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                )
            }
            await MetadataCache.shared.bulkStore(batch)
            await Task.yield()
            offset = end
        }
    }
}
