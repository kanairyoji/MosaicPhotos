#if canImport(UIKit)
import LocalPhotoCore
import Photos
import PhotoSourceKit
import SwiftUI

public struct LocalPhotoSettingsView: View {
    // 0 = Auto（端末 RAM に応じて自動）。既定は Auto。
    @AppStorage(CacheSettingsKeys.memoryLimitMB) private var memoryLimitMB = 0
    @AppStorage(CacheSettingsKeys.diskLimitMB)   private var diskLimitMB   = 500
    @State private var diskUsage = 0
    @State private var photoCount = 0
    @State private var albumCount = 0
    @State private var showClearConfirm = false

    public init() {}

    public var body: some View {
        Group {
        Section(L("Library")) {
            LabeledContent(L("Photos"), value: "\(photoCount)")
            LabeledContent(L("User albums"), value: "\(albumCount)")
        }

        Section {
            Picker(L("Memory limit"), selection: $memoryLimitMB) {
                Text(L("Auto (\(ThumbnailMemoryBudget.autoMB()) MB)")).tag(0)
                Text("60 MB").tag(60)
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
                Text("400 MB").tag(400)
            }
            Picker(L("Disk limit"), selection: $diskLimitMB) {
                Text("200 MB").tag(200)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
            }
            LabeledContent(L("Disk usage"), value: formatBytes(diskUsage))
            Button(L("Clear Photo Cache"), role: .destructive) {
                showClearConfirm = true
            }
            .alert(L("Clear Photo Cache?"), isPresented: $showClearConfirm) {
                Button(L("Clear"), role: .destructive) {
                    Task {
                        await ThumbnailCache.shared.clear()
                        diskUsage = await ThumbnailCache.shared.currentDiskUsage()
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("All locally cached thumbnails will be deleted and re-fetched as you browse."))
            }
        } header: {
            Text(L("Photo Cache"))
        } footer: {
            Text(L("Stores already-decoded, cell-sized thumbnails so the grid scrolls smoothly without re-decoding each photo (and without re-fetching iCloud-optimized originals). Full photos are never duplicated here — only small thumbnails. “Auto” scales the memory limit to this device's RAM."))
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
            // 0=Auto は端末 RAM から解決する。
            let bytes = ThumbnailMemoryBudget.effectiveBytes(forSettingMB: newVal)
            Task { await ThumbnailCache.shared.updateMemoryLimit(bytes) }
        }
        .onChange(of: diskLimitMB) { _, newVal in
            Task { await ThumbnailCache.shared.updateDiskLimit(newVal * 1024 * 1024) }
        }
    }

    // formatBytes は PhotoSourceKit の共通ヘルパへ集約。
}

/// 端末写真キャッシュの Debug 情報。app の Developer Options 画面が合成して表示する。
public struct LocalPhotoDebugSection: View {
    public init() {}
    public var body: some View {
        Section("Photos — Debug") {
            LabeledContent("Thumbnail JPEG quality", value: "0.8")
        }
    }
}
#endif
