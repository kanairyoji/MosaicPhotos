#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// 「この人物を整理」（ADR-111）: 複数の別人が混ざった人物を**グループ単位で一括分離**する。
///
/// 中身を自動でサブグループ化（束ね内クラスタ＋クラスタ内の再帰監査分割）して代表顔つきで
/// 一覧し、「別人」のグループにチェック → 1 タップでまとめて分離する。1 対 1 レビューでは
/// 追いつかない多人数混入（実フィードバック）のための画面。
public struct PersonCleanupView: View {
    public let person: PersonInfo
    public let peopleEngine: PeopleEngine
    @Environment(\.dismiss) private var dismiss

    @State private var subgroups: [PersonSubgroup] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSeparating = false
    @State private var confirmSeparate = false


    public init(person: PersonInfo, peopleEngine: PeopleEngine) {
        self.person = person
        self.peopleEngine = peopleEngine
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L("Analyzing faces…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if subgroups.count <= 1 {
                    ContentUnavailableView(
                        L("No split candidates"),
                        systemImage: "person.crop.circle.badge.checkmark",
                        description: Text("This person looks consistent. To remove individual photos, use Manage Faces."))
                } else {
                    groupList
                }
            }
            .navigationTitle(person.displayName)
            .pausesFaceScan(peopleEngine)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if subgroups.count > 1 {
                    separateButton
                }
            }
        }
        .task {
            subgroups = await peopleEngine.cleanupSubgroups(for: person)
            isLoading = false
        }
        .confirmationDialog(
            L("Separate \(selected.count) groups into new people?"),
            isPresented: $confirmSeparate, titleVisibility: .visible) {
            Button(L("Separate"), role: .destructive) { separate() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("Selected groups become separate people. The app also learns from this so they stay apart.")
        }
    }

    private var groupList: some View {
        List {
            Section {
                ForEach(subgroups) { group in
                    row(for: group)
                }
            } header: {
                Text("Found \(subgroups.count) groups")
            } footer: {
                Text("Check the groups that are NOT this person, then tap Separate. The largest group stays as this person.")
            }
        }
    }

    @ViewBuilder
    private func row(for group: PersonSubgroup) -> some View {
        // 最大グループ（先頭）は「残す側」＝選択不可。全部分離して空の人物が残るのを防ぐ。
        let isKeeper = group.id == subgroups.first?.id
        let isOn = selected.contains(group.id)
        HStack(spacing: 12) {
            FaceAvatarImage(refKey: group.coverFace?.refKey,
                            box: group.coverFace?.boundingBox, maxPixel: 240)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(group.photoCount) photos"))
                    .font(.body)
                if isKeeper {
                    Text(L("Kept as this person"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if group.isWholeCluster, let name = group.clusterName, !name.isEmpty {
                    // 束ね内の命名済みクラスタ（分離すると名前ごと独立する）。
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isKeeper {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isKeeper else { return }
            if isOn { selected.remove(group.id) } else { selected.insert(group.id) }
        }
        .opacity(isKeeper ? 0.6 : 1)
    }

    private var separateButton: some View {
        Button {
            confirmSeparate = true
        } label: {
            if isSeparating {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text(L("Separate \(selected.count) groups"))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selected.isEmpty || isSeparating)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func separate() {
        let groups = subgroups.filter { selected.contains($0.id) }
        guard !groups.isEmpty else { return }
        isSeparating = true
        Task {
            await peopleEngine.separateSubgroups(groups)
            dismiss()
        }
    }
}
#endif
