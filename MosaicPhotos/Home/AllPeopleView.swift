import AutoAlbumCore
import SwiftUI

/// ピープルの全一覧（ADR-67）。
///
/// 成長期の子供がいるライブラリでは同一人物が多数のクラスタに分裂し得るため、ホームの
/// 横スクロールカルーセルには枚数上位だけを出し、残りはここで扱う。枚数降順のグリッドに
/// 名前検索と「まとめて確認」への導線を置き、分裂した人物を畳む作業をこの画面に集約する。
struct AllPeopleView: View {
    let people: [PersonInfo]
    let onSelect: (PersonInfo) -> Void
    let onLongPress: (PersonInfo) -> Void
    /// 「まとめて確認」（グリッド一括レビュー）。
    var onBatchReview: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let columns = [GridItem(.adaptive(minimum: 92), spacing: 14)]

    private var filtered: [PersonInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    /// 名前が付いていない小さなクラスタの数＝「分裂して散らばっている」量の目安。
    private var unnamedSmallCount: Int {
        people.filter { $0.name == nil && $0.count < 10 }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if unnamedSmallCount >= 50, let onBatchReview {
                    splitHint(action: onBatchReview)
                }
                LazyVGrid(columns: Self.columns, spacing: 16) {
                    ForEach(filtered) { person in
                        PersonGridCell(person: person)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismiss()
                                onSelect(person)
                            }
                            .onLongPressGesture(minimumDuration: 0.4) { onLongPress(person) }
                    }
                }
                .padding(16)
            }
            .searchable(text: $query, prompt: L("Search people"))
            .navigationTitle(L("People"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(verbatim: "\(people.count)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 分裂が多いときの案内。原因（同じ人が別々に認識されている）と、畳む手段を示す。
    private func splitHint(action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("The same person may be split into several entries."),
                  systemImage: "person.2.badge.gearshape")
                .font(.subheadline.weight(.semibold))
            Text(L("Children change a lot as they grow, so one child can end up as many entries. Confirm them together to merge them quickly."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: action) {
                Label(L("Confirm together"), systemImage: "square.grid.3x3.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// グリッド 1 セル（代表顔＋名前＋枚数）。
private struct PersonGridCell: View {
    let person: PersonInfo

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatarImage(refKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 400)
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(person.displayName)
                .font(.caption)
                .lineLimit(1)
            Text(verbatim: "\(person.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
