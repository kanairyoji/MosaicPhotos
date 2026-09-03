#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// 対象人物を選ぶ（枚数降順・名前検索）。
struct InspectorPersonPicker: View {
    let people: [PersonInfo]
    let onPick: (PersonInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PersonInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { person in
                Button {
                    onPick(person); dismiss()
                } label: {
                    HStack {
                        Text(person.displayName).foregroundStyle(.primary)
                        Spacer()
                        Text("\(person.count)").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: L("Search people"))
            .navigationTitle(L("Choose Person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
            }
        }
    }
}
#endif
