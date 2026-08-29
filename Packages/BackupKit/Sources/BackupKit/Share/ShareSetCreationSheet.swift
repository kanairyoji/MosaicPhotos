#if canImport(UIKit)
import DropboxKit
import SwiftUI

// MARK: - 共有セット作成シート
//
// ⚠️ もとはアプリターゲット。作成元はアルバム・人物・グループの 3 か所で、人物とグループの UI は
// `PeopleKit` へ出た。共有そのものの UI なので `ShareSyncEngine` と同じパッケージに置く。

/// アルバム／人物から「家族と共有…」で開く作成シート。
public struct ShareSetCreationSheet: View {
    let suggestedName: String
    let refKeys: [String]
    let shareEngine: ShareSyncEngine
    /// 作成元（グループ/人物/アルバム）。元カードの「クラウド共有中」バッジ表示に使う。
    var sourceKey: String?

    public init(suggestedName: String, refKeys: [String], shareEngine: ShareSyncEngine,
                sourceKey: String? = nil) {
        self.suggestedName = suggestedName
        self.refKeys = refKeys
        self.shareEngine = shareEngine
        self.sourceKey = sourceKey
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Set name"), text: $name)
                } footer: {
                    Text(String(format: L("%d photos will be copied into a folder with this name inside your shared folder. Originals and backups are not moved. AI analysis (tags, search index, faces) is included so receiving devices don't re-analyze them."), refKeys.count))
                }
            }
            .navigationTitle(L("Cloud Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(L("Share")) {
                            isCreating = true
                            Task {
                                await shareEngine.createSet(name: name, refKeys: refKeys,
                                                            sourceKey: sourceKey)
                                dismiss()
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { if name.isEmpty { name = suggestedName } }
        }
    }
}
#endif
