import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import SwiftUI

/// 「Storage」：キャッシュ使用量の概観と、ユーザー向けの一括消去（Clear All Caches）。
/// 個別ソースのキャッシュ上限は各ソースの設定画面、細粒度の消去は Developer Options に置く。
struct StorageSettingsView: View {
    let store: DropboxPhotoStore?
    let placeScanner: PlaceScanner?

    @State private var photoCacheBytes = 0
    @State private var isClearing = false
    @State private var showConfirm = false

    var body: some View {
        Form {
            Section("Usage") {
                LabeledContent("Photo thumbnail cache", value: formattedBytes(photoCacheBytes))
            }

            Section {
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    if isClearing {
                        HStack { ProgressView().controlSize(.small); Text("Clearing…") }
                    } else {
                        Text("Clear All Caches")
                    }
                }
                .disabled(isClearing)
                .confirmationDialog("Clear all caches?", isPresented: $showConfirm, titleVisibility: .visible) {
                    Button("Clear All", role: .destructive) { Task { await clearAll() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Photo thumbnails, Dropbox cache, and place index will all be deleted and rebuilt as you browse.")
                }
            } footer: {
                Text("Frees disk space. Cached images are re-fetched on demand, so the app stays fully functional.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { photoCacheBytes = await ThumbnailCache.shared.currentDiskUsage() }
    }

    private func clearAll() async {
        isClearing = true
        defer { isClearing = false }
        await ThumbnailCache.shared.clear()
        if let store { await store.clearCache() }
        if let placeScanner { await placeScanner.clearCache() }
        photoCacheBytes = await ThumbnailCache.shared.currentDiskUsage()
    }
}
