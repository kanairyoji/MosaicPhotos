#if canImport(UIKit)
import SwiftUI

/// オフロード（バックアップ済み写真の端末からの削除・ADR-40）の画面。
/// **ドライラン（何も消さない検証一覧）が主役**で、実削除は Developer Options のゲート
/// （`BackupSettingsKeys.offloadRealDeletionEnabled`）が ON のときだけボタンが現れる。
/// 実削除も PhotoKit 経由＝OS の確認ダイアログが必ず出て、30 日間は「最近削除した項目」から
/// 復元できる。段階導入（ドライラン運用 → 少数で実削除 → 拡大）を前提にした構成。
public struct OffloadSettingsView: View {
    let engine: BackupEngine

    @AppStorage(BackupSettingsKeys.offloadRealDeletionEnabled) private var realDeletionEnabled = false
    @AppStorage(BackupSettingsKeys.offloadMaxPerRun) private var maxPerRun = 10
    /// 自動オフロードの発動条件（空き容量 MB・0 = オフロードしない）。本体は未実装のため、
    /// 0 以外を選ぶと案内を出して 0 へ戻す（設定枠の先行実装）。
    @AppStorage(BackupSettingsKeys.offloadAutoThresholdMB) private var autoThresholdMB = 0
    @State private var plan: OffloadPlan?
    @State private var isPlanning = false
    @State private var isExecuting = false
    @State private var lastResult: String?
    @State private var showsNotImplemented = false

    public init(engine: BackupEngine) {
        self.engine = engine
    }

    public var body: some View {
        List {
            Section {
                Text(L("Offload removes photos from this device after verifying that an identical copy exists in Dropbox (content hash match). Deleted photos remain in Recently Deleted for 30 days."))
                    .font(.footnote).foregroundStyle(.secondary)
                Picker(L("Photos per run"), selection: $maxPerRun) {
                    ForEach([5, 10, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                }
            }

            Section {
                Picker(L("Auto offload"), selection: $autoThresholdMB) {
                    Text(L("Don't offload")).tag(0)
                    ForEach([125, 250, 500, 1024, 2048], id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                }
            } footer: {
                Text(L("When free space on this device drops below the selected amount, verified old photos will be offloaded automatically."))
            }
            .onChange(of: autoThresholdMB) { _, newValue in
                // 自動オフロード本体は未実装。選択されたら案内を出して「オフロードしない」へ戻す。
                if newValue != 0 {
                    showsNotImplemented = true
                    autoThresholdMB = 0
                }
            }

            Section {
                Button {
                    isPlanning = true
                    Task {
                        plan = await engine.planOffload(limit: maxPerRun)
                        isPlanning = false
                    }
                } label: {
                    if isPlanning {
                        HStack { ProgressView(); Text(L("Verifying…")) }
                    } else {
                        Label(L("Check candidates (nothing is deleted)"), systemImage: "checklist")
                    }
                }
                .disabled(isPlanning || isExecuting)
            }

            if let plan {
                planSections(plan)
            }

            if let lastResult {
                Section(L("Last result")) {
                    Text(lastResult).font(.footnote)
                }
            }
        }
        .navigationTitle(L("Offload"))
        .alert(L("Auto offload is not available yet"), isPresented: $showsNotImplemented) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(L("Automatic offloading is not implemented yet. The setting has been reset to “Don't offload”."))
        }
    }

    @ViewBuilder
    private func planSections(_ plan: OffloadPlan) -> some View {
        Section(header: Text(L("Ready to offload (verified)")),
                footer: plan.eligible.isEmpty ? nil
                    : Text(realDeletionEnabled
                        ? L("Deletion asks for system confirmation and can be undone from Recently Deleted for 30 days.")
                        : L("Deletion is disabled. Enable it in Developer Options to delete for real."))) {
            if plan.eligible.isEmpty {
                Text(L("No photos passed verification.")).foregroundStyle(.secondary)
            }
            ForEach(plan.eligible) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(.subheadline)
                    Text(item.captureDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !plan.eligible.isEmpty && realDeletionEnabled {
                Button(role: .destructive) {
                    isExecuting = true
                    Task {
                        let result = await engine.executeOffload(limit: maxPerRun)
                        lastResult = String(format: L("Deleted %d photo(s), skipped %d."),
                                            result.deleted.count, result.skipped.count)
                        self.plan = nil
                        isExecuting = false
                    }
                } label: {
                    if isExecuting {
                        HStack { ProgressView(); Text(L("Deleting…")) }
                    } else {
                        Label(String(format: L("Delete %d photo(s) from this device"),
                                     plan.eligible.count),
                              systemImage: "trash")
                    }
                }
                .disabled(isExecuting)
            }
        }

        if !plan.skipped.isEmpty {
            Section(L("Skipped (kept on device)")) {
                ForEach(plan.skipped) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename).font(.subheadline)
                        Text(item.skipReason ?? "").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
#endif
