#if canImport(UIKit)
import SwiftUI

/// フィルタボタン（下部バー中央）から開く、絞り込み条件の指定シート。
/// 条件は `PhotoFilter`（現状はお気に入りのみ）。変更は Binding で即時にグリッドへ反映される。
struct PhotoFilterSheet: View {
    @Binding var filter: PhotoFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $filter.favoritesOnly) {
                        Label {
                            Text(L("Favorites only"))
                        } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                        }
                    }
                } footer: {
                    Text(L("Show only photos marked as favorites. Cloud photos have no favorites and will be hidden."))
                }
            }
            .navigationTitle(L("Filter Photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif
