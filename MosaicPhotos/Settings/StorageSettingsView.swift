import DropboxKit
import ImageCacheKit
import LocalPhotoKit
import PhotosFeatureKit
import SwiftUI

/// 「Storage」：アプリ全体の**キャッシュ予算**（ADR-185）と、キャッシュごとの使用量・一括消去。
///
/// キャッシュごとの上限は持たない。1 つの予算（既定＝端末の総容量の 10%）を全キャッシュが共有し、
/// 超えたら価値の低い順（本体画像 → 派生物 → サムネ）に捨てる。ここで変えられるのは予算だけ。
struct StorageSettingsView: View {
    let store: DropboxPhotoStore?
    let placeScanner: PlaceScanner?

    @State private var snapshot: CacheBudgetCoordinator.Snapshot?
    @State private var isClearing = false
    @State private var showConfirm = false
    /// Picker 用の選択（%）。`fixedTag` のときは固定 GB。
    @State private var mode = CacheBudget.defaultPercent
    @State private var fixedGB = 10
    private let fixedTag = -1

    var body: some View {
        Form {
            budgetSection
            usageSection
            clearSection
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: mode) { _, _ in applySetting() }
        .onChange(of: fixedGB) { _, _ in if mode == fixedTag { applySetting() } }
    }

    // MARK: - 予算

    private var budgetSection: some View {
        Section {
            Picker("Cache limit", selection: $mode) {
                ForEach(CacheBudget.percentChoices, id: \.self) { p in
                    Text(p == CacheBudget.defaultPercent
                         ? L("\(p)%% of storage (default)")
                         : L("\(p)%% of storage")).tag(p)
                }
                Text(L("Fixed size")).tag(fixedTag)
            }
            if mode == fixedTag {
                Picker("Fixed size", selection: $fixedGB) {
                    ForEach(CacheBudget.fixedGBChoices, id: \.self) { g in Text("\(g) GB").tag(g) }
                }
            }
            if let snapshot {
                LabeledContent("Budget", value: formattedBytes(snapshot.effectiveBudget))
                if snapshot.effectiveBudget < snapshot.nominalBudget {
                    Text(L("Reduced from \(formattedBytes(snapshot.nominalBudget)) to keep free space on this device."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Cache Limit")
        } footer: {
            Text("All caches share one limit. When it is reached, the app removes the least valuable items first: full-size cloud photos (prefetched ones before viewed ones), then face avatars, and thumbnails last. Nothing you browse is ever unavailable — removed items are simply fetched again.")
        }
    }

    // MARK: - 使用量

    private var usageSection: some View {
        Section {
            if let snapshot {
                ForEach(snapshot.entries, id: \.id) { entry in
                    LabeledContent(label(for: entry.id), value: formattedBytes(entry.usage))
                }
                LabeledContent("Total", value: formattedBytes(snapshot.totalUsage))
                if snapshot.effectiveBudget > 0 {
                    ProgressView(value: Double(min(snapshot.totalUsage, snapshot.effectiveBudget)),
                                 total: Double(snapshot.effectiveBudget))
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Usage")
        }
    }

    private func label(for id: String) -> String {
        switch id {
        case "local.thumbnails":   return L("Thumbnails (device photos)")
        case "dropbox.thumbnails": return L("Thumbnails (Dropbox)")
        case "dropbox.fullImages": return L("Full-size photos (Dropbox)")
        case "faces.avatars":      return L("Face avatars")
        default: return id
        }
    }

    // MARK: - 消去

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                BusyLabel("Clear All Caches", busy: "Clearing…", isBusy: isClearing)
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

    // MARK: - 読み書き

    private func load() async {
        let setting = CacheBudget.setting()
        mode = setting.isFixed ? fixedTag : setting.percent
        if setting.isFixed { fixedGB = setting.fixedGB }
        snapshot = await CacheBudgetCoordinator.shared.snapshot()
    }

    private func applySetting() {
        let setting = mode == fixedTag
            ? CacheBudget.Setting(percent: CacheBudget.defaultPercent, fixedGB: fixedGB)
            : CacheBudget.Setting(percent: mode, fixedGB: 0)
        guard setting != CacheBudget.setting() else { return }
        CacheBudget.save(setting)
        Task {
            // 小さくしたなら、その場で予算に収める。
            await CacheBudgetCoordinator.shared.rebalance()
            snapshot = await CacheBudgetCoordinator.shared.snapshot()
        }
    }

    private func clearAll() async {
        isClearing = true
        defer { isClearing = false }
        await ThumbnailCache.shared.clear()
        if let store { await store.clearCache() }
        if let placeScanner { await placeScanner.clearCache() }
        snapshot = await CacheBudgetCoordinator.shared.snapshot()
    }
}
