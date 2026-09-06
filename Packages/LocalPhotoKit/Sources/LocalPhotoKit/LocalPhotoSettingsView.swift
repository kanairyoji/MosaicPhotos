#if canImport(UIKit)
import LocalPhotoCore
import Photos
import PhotoSourceKit
import SwiftUI

public struct LocalPhotoSettingsView: View {
    // 0 = Auto（端末 RAM に応じて自動）。既定は Auto。
    @AppStorage(CacheSettingsKeys.memoryLimitMB) private var memoryLimitMB = 0
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

        // メモリ（表示中のサムネを保持する量）とディスク（サムネの保存量）は別物なので節を分ける
        // （実フィードバック: 「メモリのセクションにディスク上限がある」）。
        Section {
            Picker(L("Memory limit"), selection: $memoryLimitMB) {
                Text(L("Auto (\(ThumbnailMemoryBudget.autoMB()) MB)")).tag(0)
                Text("60 MB").tag(60)
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
                Text("400 MB").tag(400)
            }
        } header: {
            Text(L("Thumbnails in Memory"))
        } footer: {
            Text(L("How many decoded thumbnails stay in memory for instant scrolling. “Auto” scales to this device's RAM."))
        }

        Section {
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
            Text(L("Thumbnails on Disk"))
        } footer: {
            Text(L("Stores already-decoded, cell-sized thumbnails so the grid scrolls smoothly without re-decoding each photo (and without re-fetching iCloud-optimized originals). Full photos are never duplicated here — only small thumbnails (about 20–40 KB each). The size is governed by the app-wide cache limit in Settings → Storage; thumbnails are the last thing removed when that limit is reached."))
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
    }

    // formatBytes は PhotoSourceKit の共通ヘルパへ集約。
}

/// 端末写真キャッシュの Debug 情報。app の Developer Options 画面が合成して表示する。
public struct LocalPhotoDebugSection: View {
    public init() {}
    public var body: some View {
        Section("写真ソース：ローカル（端末）") {
            LabeledContent("サムネの JPEG 品質", value: "0.8")
        }
    }
}
#endif
