#if canImport(UIKit)
import LocalPhotoCore
import Photos
import SwiftUI

public struct LocalPhotoSettingsView: View {
    @AppStorage(CacheSettingsKeys.memoryLimitMB) private var memoryLimitMB = 100
    @AppStorage(CacheSettingsKeys.diskLimitMB)   private var diskLimitMB   = 500
    @State private var diskUsage = 0
    @State private var photoCount = 0
    @State private var albumCount = 0
    @State private var showClearConfirm = false

    public init() {}

    public var body: some View {
        Group {
        Section("Library") {
            LabeledContent("Photos", value: "\(photoCount)")
            LabeledContent("User albums", value: "\(albumCount)")
        }

        Section("Photo Cache") {
            Picker("Memory limit", selection: $memoryLimitMB) {
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
                Text("400 MB").tag(400)
            }
            Picker("Disk limit", selection: $diskLimitMB) {
                Text("200 MB").tag(200)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
            }
            LabeledContent("Disk usage", value: formatBytes(diskUsage))
            Button("Clear Photo Cache", role: .destructive) {
                showClearConfirm = true
            }
            .alert("Clear Photo Cache?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) {
                    Task {
                        await ThumbnailCache.shared.clear()
                        diskUsage = await ThumbnailCache.shared.currentDiskUsage()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All locally cached thumbnails will be deleted and re-fetched as you browse.")
            }
        }

        Section("Debug") {
            LabeledContent("Thumbnail JPEG quality", value: "0.8")
        }
        }
        .task {
            diskUsage = await ThumbnailCache.shared.currentDiskUsage()
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                photoCount = PHAsset.fetchAssets(with: .image, options: nil).count
                albumCount = PHAssetCollection.fetchAssetCollections(
                    with: .album, subtype: .albumRegular, options: nil).count
            }
        }
        .onChange(of: memoryLimitMB) { _, newVal in
            Task { await ThumbnailCache.shared.updateMemoryLimit(newVal * 1024 * 1024) }
        }
        .onChange(of: diskLimitMB) { _, newVal in
            Task { await ThumbnailCache.shared.updateDiskLimit(newVal * 1024 * 1024) }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
#endif
