#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

/// Full-screen debug view showing the contents of the DropboxKit SwiftData cache.
/// Reached via a NavigationLink from `DropboxSettingsView`.
public struct DropboxCacheListView: View {
    let model: DropboxCacheDebugModel

    public init(model: DropboxCacheDebugModel) {
        self.model = model
    }

    public var body: some View {
        List {
            summarySection
            itemsSection
            usageSection
        }
        .navigationTitle("Cache Contents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { model.refresh() }
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Summary") {
            if let s = model.stats {
                LabeledContent("Files in DB", value: "\(s.itemCount)")
                LabeledContent("Thumbnails", value: "\(s.thumbnailCount)  (\(formatBytes(s.thumbnailBytes)))")
                LabeledContent("Full images", value: "\(s.fullImageCount)  (\(formatBytes(s.fullImageBytes)))")
                if let d = s.lastSyncedAt {
                    LabeledContent("Last synced", value: DisplayDate.dateTime(d))
                }
                if let cursor = s.syncCursor {
                    LabeledContent("Sync cursor") {
                        Text(cursor.prefix(24) + (cursor.count > 24 ? "…" : ""))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No data — tap Refresh")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var itemsSection: some View {
        Section("Cached Files (\(model.items.count))") {
            if model.items.isEmpty {
                Text("No cached file metadata")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private var usageSection: some View {
        Section("Usage Entries (\(model.usageEntries.count))") {
            if model.usageEntries.isEmpty {
                Text("No usage entries")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.usageEntries) { entry in
                    usageRow(entry)
                }
            }
        }
    }

    // MARK: - Row builders

    private func itemRow(_ item: DropboxCacheDebugModel.ItemRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.subheadline)
            Text(item.id)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if let hash = item.contentHash {
                    Text(hash.prefix(8))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if let captureDate = item.captureDate {
                    Text(DisplayDate.ymd(captureDate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(DisplayDate.dateTime(item.cachedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func usageRow(_ entry: DropboxCacheDebugModel.UsageRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == "thumbnail" ? "photo" : "photo.artframe")
                .foregroundStyle(entry.kind == "thumbnail" ? Color.blue : Color.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(DisplayDate.dateTime(entry.lastAccessedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(entry.byteSize))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
#endif
