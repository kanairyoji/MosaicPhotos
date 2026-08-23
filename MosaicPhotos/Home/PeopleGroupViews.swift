import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - グループカード（カルーセル用）

/// ピープルグループのカード。単人のカード（1 枚の顔アバター）と見分けがつくよう、
/// メンバー顔の 2×2 コラージュ＋グループバッジ＋アクセント枠で表示する。
struct PeopleGroupCard: View {
    let group: PeopleGroupInfo
    private static let side: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                collage
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
                // グループバッジ（単人カードとの見分けの決め手）。
                Image(systemName: "person.2.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 5, y: 5)
            }
            Label {
                Text(group.name).lineLimit(1)
            } icon: {
                Image(systemName: "person.2").font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
        }
        .frame(width: Self.side + 12)
    }

    /// メンバー先頭 4 人の顔コラージュ（1 人でも欠けたら残りはプレースホルダ）。
    private var collage: some View {
        let shown = Array(group.members.prefix(4))
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                memberAvatar(shown.indices.contains(0) ? shown[0] : nil)
                memberAvatar(shown.indices.contains(1) ? shown[1] : nil)
            }
            GridRow {
                memberAvatar(shown.indices.contains(2) ? shown[2] : nil)
                memberAvatar(shown.indices.contains(3) ? shown[3] : nil)
            }
        }
    }

    @ViewBuilder
    private func memberAvatar(_ person: PersonInfo?) -> some View {
        if let person {
            FaceAvatarImage(refKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 240)
        } else {
            Color(uiColor: .secondarySystemBackground)
        }
    }
}

// MARK: - 作成・編集シート

/// グループの作成/編集（名前＋メンバー複数選択）。`editing` が nil なら新規作成。
struct PeopleGroupEditorSheet: View {
    let peopleEngine: PeopleEngine
    var editing: PeopleGroupInfo?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<Int> = []
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Group name (e.g. family, team)"), text: $name)
                } footer: {
                    Text(L("Groups collect several people into one album (a family, a team, an organization). Select at least 2 people."))
                }
                Section(L("Members")) {
                    ForEach(peopleEngine.people) { person in
                        Button {
                            if selected.contains(person.clusterID) {
                                selected.remove(person.clusterID)
                            } else {
                                selected.insert(person.clusterID)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                FaceAvatarImage(refKey: person.coverRefKey,
                                                box: person.coverBoundingBox, maxPixel: 160)
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                                Text(person.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(person.clusterID) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? L("New People Group") : L("Edit Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(editing == nil ? L("Create") : L("Save")) {
                            isSaving = true
                            Task {
                                // 記録上のメンバー順を保ちつつ、追加分を末尾へ。
                                let base = (editing?.memberClusterIDs ?? []).filter { selected.contains($0) }
                                let added = selected.subtracting(base).sorted()
                                let members = base + added
                                if let editing {
                                    await peopleEngine.updatePeopleGroup(
                                        id: editing.id, name: name, memberClusterIDs: members)
                                } else {
                                    await peopleEngine.createPeopleGroup(
                                        name: name, memberClusterIDs: members)
                                }
                                dismiss()
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || selected.count < 2)
                    }
                }
            }
            .onAppear {
                guard let editing, name.isEmpty, selected.isEmpty else { return }
                name = editing.name
                selected = Set(editing.memberClusterIDs)
            }
        }
    }
}

// MARK: - グループ長押しメニュー

/// グループカードの長押し/「…」メニューと配下のシート・確認一式。
struct PeopleGroupActionsModifier: ViewModifier {
    @Binding var target: PeopleGroupInfo?
    let peopleEngine: PeopleEngine

    @Environment(ShareSyncEngine.self) private var shareEngine: ShareSyncEngine?
    @State private var editingGroup: PeopleGroupInfo?
    @State private var sharingGroup: SharePayload?
    @State private var deletingGroup: PeopleGroupInfo?

    /// クラウド共有シートの素材。グループの写真キーは開く前に解決する
    /// （一覧の PersonInfo.memberRefKeys は遅延取得で空のため・ADR-95）。
    private struct SharePayload: Identifiable {
        let group: PeopleGroupInfo
        let refKeys: [String]
        var id: UUID { group.id }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(target?.name ?? "",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                presenting: target) { group in
                Button(L("Edit Group…")) { editingGroup = group }
                if shareEngine != nil {
                    Button(L("Cloud Share…")) {
                        Task {
                            let refKeys = await peopleEngine.memberRefKeys(forGroup: group.id)
                            sharingGroup = SharePayload(group: group, refKeys: refKeys)
                        }
                    }
                }
                Button(L("Delete Group"), role: .destructive) { deletingGroup = group }
                Button(L("Cancel"), role: .cancel) {}
            }
            .sheet(item: $editingGroup) { group in
                PeopleGroupEditorSheet(peopleEngine: peopleEngine, editing: group)
            }
            .sheet(item: $sharingGroup) { payload in
                if let shareEngine {
                    ShareSetCreationSheet(suggestedName: payload.group.name,
                                          refKeys: payload.refKeys,
                                          shareEngine: shareEngine)
                }
            }
            .confirmationDialog(
                L("Delete this group? People and their photos are not affected."),
                isPresented: Binding(get: { deletingGroup != nil },
                                     set: { if !$0 { deletingGroup = nil } }),
                titleVisibility: .visible, presenting: deletingGroup
            ) { group in
                Button(L("Delete Group"), role: .destructive) {
                    Task { await peopleEngine.deletePeopleGroup(id: group.id) }
                }
            }
    }
}

extension View {
    func peopleGroupActions(for target: Binding<PeopleGroupInfo?>,
                            engine: PeopleEngine) -> some View {
        modifier(PeopleGroupActionsModifier(target: target, peopleEngine: engine))
    }
}

// MARK: - グループアルバム表示

/// グループの写真アルバム（全メンバーの写真の合成・PersonAlbumView と同型）。
struct PeopleGroupAlbumView: View {
    private let group: PeopleGroupInfo
    private let dropboxStore: DropboxPhotoStore
    private let peopleEngine: PeopleEngine
    private let assetIndex: LocalAssetIndex

    @State private var store: MergedPhotoStore?
    @State private var menuTarget: PeopleGroupInfo?

    init(group: PeopleGroupInfo, dropboxStore: DropboxPhotoStore,
         assetIndex: LocalAssetIndex, peopleEngine: PeopleEngine) {
        self.group = group
        self.dropboxStore = dropboxStore
        self.peopleEngine = peopleEngine
        self.assetIndex = assetIndex
    }

    var body: some View {
        Group {
            if let store {
                PhotoSourceContentView(store: store, title: group.name)
                    .environment(\.sourceMenuContent) { [group] in
                        AnyView(
                            Button { menuTarget = group } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel(Text("Group options"))
                        )
                    }
                    .peopleGroupActions(for: $menuTarget, engine: peopleEngine)
            } else {
                Color.clear.busyOverlay(true, text: L("Loading photos…"))
            }
        }
        .task {
            guard store == nil else { return }
            let members = await peopleEngine.memberRefKeys(forGroup: group.id)
            let refs = members.compactMap(PhotoRef.decode)
            store = .forMembers(localIDs: refs.compactMap(\.localIdentifier),
                                cloudPaths: refs.compactMap(\.cloudPath),
                                dropboxStore: dropboxStore, assetIndex: assetIndex)
        }
    }
}
