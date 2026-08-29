#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// 「この写真は別の人」で**正しい人物を選ぶ**シート（人物アルバムのサムネイル／全画面から呼ぶ）。
///
/// ⚠️ 顔だけを並べた「顔の管理」と違い、ここは**写真を見ている流れ**で直せることが要点
/// （実フィードバック: 全体像や前後関係で「この人ではない」と気づく）。「この人ではない」が
/// 相手を選ばずに外すのに対し、こちらは**付け替え先を選ぶ**＝その人物の確認顔（アンカー）として
/// 学習されるので、次から同じ顔はその人物に入る（ADR-46）。
struct PhotoPersonPickerView: View {
    /// 付け替える写真（表示側の ID）。
    let itemID: String
    /// いま開いている人物（＝付け替え元）。一覧から除く。
    let currentClusterID: Int
    let peopleEngine: PeopleEngine
    /// 選択された人物（nil＝新しい人物）。
    let onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [PersonInfo] {
        let people = peopleEngine.people.filter { $0.clusterID != currentClusterID }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil); dismiss()
                    } label: {
                        Label(L("New Person"), systemImage: "person.crop.circle.badge.plus")
                    }
                } footer: {
                    Text(L("Moves this photo’s face to the person you choose. The app learns from this, so the same face goes to that person next time."))
                }
                Section(L("Choose the correct person")) {
                    ForEach(candidates) { person in
                        Button {
                            onPick(person.clusterID); dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                FaceAvatarImage(refKey: person.coverRefKey,
                                                box: person.coverBoundingBox, maxPixel: 200)
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                Text(person.displayName).foregroundStyle(.primary)
                                Spacer()
                                Text(L("\(person.count) photos"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: L("Search people"))
            .navigationTitle(L("Someone Else"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
    }
}
#endif
