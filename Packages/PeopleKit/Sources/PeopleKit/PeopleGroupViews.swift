#if canImport(UIKit)
import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - クラウド共有中バッジ（人物・グループ・アルバムのカード共通）

/// 「このカードの写真をクラウド共有している」ことを示すバッジ。
/// アイコンは共有導線（メニュー・設定）と同じ `icloud.and.arrow.up` に統一する。
public struct CloudSharedBadge: View {
    public init() {}

    public var body: some View {
        Image(systemName: "icloud.and.arrow.up")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Color.accentColor, in: Circle())
            .offset(x: 5, y: 5)
            .accessibilityLabel(L("Cloud Sharing"))
    }
}

// MARK: - グループカード（カルーセル用）

/// ピープルグループのカード。単人のカード（1 枚の顔アバター）と見分けがつくよう、
/// メンバー顔の 2×2 コラージュ＋グループバッジ＋アクセント枠で表示する。
public struct PeopleGroupCard: View {
    public let group: PeopleGroupInfo
    /// このグループがクラウド共有中か（共有セットの sourceKey で判定）。
    public var isCloudShared = false
    private static let side: CGFloat = 84

    public init(group: PeopleGroupInfo, isCloudShared: Bool = false) {
        self.group = group
        self.isCloudShared = isCloudShared
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // グループであることは 2×2 コラージュ自体で伝わるので、追加のグループ印は
                // 置かない（実フィードバック: バッジ・名前横アイコンは意味が重複して混乱の元）。
                collage
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
                // クラウド共有中バッジ（共通ビュー）。
                if isCloudShared { CloudSharedBadge() }
            }
            Text(group.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Self.side + 6)   // PersonCard と同じ詰め幅
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
public struct PeopleGroupEditorSheet: View {
    public let peopleEngine: PeopleEngine
    public var editing: PeopleGroupInfo?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<Int> = []
    /// シートを開いた時点の記録上のメンバー（一覧に出す基準）。
    /// ⚠️ いまのチェック状態で絞ると、隠れていたメンバーを外した瞬間に行が消えて戻せなくなる。
    @State private var initialMembers: Set<Int> = []
    @State private var isSaving = false

    /// 同じ名前のグループが既にあるか（自分自身の編集は除く）。
    private var nameIsTaken: Bool {
        peopleEngine.peopleGroupNameExists(name, excluding: editing?.id)
    }

    /// メンバーを 1 つも変えていない（名前だけ直す）か。
    private var isRenameOnly: Bool { editing != nil && selected == initialMembers }

    /// 保存してよいか（規則は `PeopleGroupSelection.allowsSave`・テスト対象）。
    ///
    /// ⚠️ 母数は `allPeople`（**表示フロアで隠した人も数える**）。`people` は「一覧に出すか」
    /// だけの線（ADR-125）なので、フロア未満のメンバーが入っているグループを編集すると
    /// 保存できなくなる。数えるのは ID でなく**人物**で、解決できない記録上の ID も 1 人。
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !nameIsTaken else {
            return false
        }
        return PeopleGroupSelection.allowsSave(
            memberCount: PeopleGroupSelection.memberCount(in: selected,
                                                          among: peopleEngine.allPeople),
            isRenameOnly: isRenameOnly)
    }

    /// 選べる人の一覧（規則は `PeopleGroupSelection.selectable`・テスト対象）。
    private var selectableMembers: [PersonInfo] {
        PeopleGroupSelection.selectable(shown: peopleEngine.people,
                                       all: peopleEngine.allPeople,
                                       initialMembers: initialMembers)
    }


    public init(peopleEngine: PeopleEngine, editing: PeopleGroupInfo? = nil) {
        self.peopleEngine = peopleEngine
        self.editing = editing
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Group name (e.g. family, team)"), text: $name)
                } footer: {
                    if nameIsTaken {
                        // 共有フォルダ名がグループ名から決まるので、同名は作らせない。
                        Label(L("A group with this name already exists."),
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text(L("Groups collect several people into one album (a family, a team, an organization). Select at least 2 people."))
                    }
                }
                Section(L("Members")) {
                    ForEach(selectableMembers) { person in
                        Button {
                            // ⚠️ **記録が代表以外のクラスタを指していることがある**（ADR-232）。
                            // 代表は束ねの中で入れ替わるので、外すときは**その人物の全 ID**を
                            // 落とす。代表 ID だけ見ていると、チェックが付いていない人を
                            // 「追加」して**同じ人物が 2 回**記録に入る（表示は重複排除で
                            // 隠れるが、共有の写真キーは同じ束ねを 2 度展開する）。
                            if PeopleGroupSelection.isSelected(person, in: selected) {
                                selected.subtract(PeopleGroupSelection.ids(of: person))
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
                                if PeopleGroupSelection.isSelected(person, in: selected) {
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
                            let renameOnly = isRenameOnly
                            Task {
                                // 記録上のメンバー順を保ちつつ、追加分を末尾へ。
                                let base = (editing?.memberClusterIDs ?? []).filter { selected.contains($0) }
                                let added = selected.subtracting(base).sorted()
                                let members = base + added
                                if let editing {
                                    // ⚠️ 名前だけ直すときは**メンバーを渡さない**（nil = 変更しない）。
                                    // 渡すと `updatePeopleGroup` の「2 人以上」ガードに当たり、
                                    // 再スキャン中（メンバーが空/1 人）は改名が黙って捨てられる。
                                    await peopleEngine.updatePeopleGroup(
                                        id: editing.id, name: name,
                                        memberClusterIDs: renameOnly ? nil : members)
                                } else {
                                    await peopleEngine.createPeopleGroup(
                                        name: name, memberClusterIDs: members)
                                }
                                dismiss()
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                guard let editing, name.isEmpty, selected.isEmpty else { return }
                name = editing.name
                selected = Set(editing.memberClusterIDs)
                initialMembers = selected
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
    @AppStorage(ShareSettingsKeys.provideEnabled) private var shareProvideEnabled = true
    @State private var editingGroup: PeopleGroupInfo?
    @State private var sharingGroup: SharePayload?
    @State private var deletingGroup: PeopleGroupInfo?
    /// クラウド共有の停止対象（共有中のときだけメニューに出す）。
    @State private var stoppingShare: StopSharingTarget?

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
                // 共有中なら「停止」、していなければ「共有…」——同じ場所で対になるようにする。
                if let shareEngine, shareProvideEnabled {
                    if let setID = shareEngine.sharedSetID(
                        sourceKey: ShareSourceKey.group(group.id).encoded, name: group.name) {
                        Button(L("Stop Cloud Sharing…"), role: .destructive) {
                            stoppingShare = StopSharingTarget(setID: setID, name: group.name)
                        }
                    } else {
                        Button(L("Cloud Share…")) {
                            Task {
                                let refKeys = await peopleEngine.memberRefKeys(forGroup: group.id)
                                sharingGroup = SharePayload(group: group, refKeys: refKeys)
                            }
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
                                          shareEngine: shareEngine,
                                          sourceKey: ShareSourceKey.group(payload.group.id).encoded)
                }
            }
            .stopSharingConfirmation($stoppingShare, shareEngine: shareEngine)
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
    public func peopleGroupActions(for target: Binding<PeopleGroupInfo?>,
                            engine: PeopleEngine) -> some View {
        modifier(PeopleGroupActionsModifier(target: target, peopleEngine: engine))
    }
}

// MARK: - グループアルバム表示

/// グループの写真アルバム（全メンバーの写真の合成・PersonAlbumView と同型）。
public struct PeopleGroupAlbumView: View {
    private let group: PeopleGroupInfo
    private let dropboxStore: DropboxPhotoStore
    private let peopleEngine: PeopleEngine
    private let assetIndex: LocalAssetIndex

    @State private var store: MergedPhotoStore?
    @State private var menuTarget: PeopleGroupInfo?

    public init(group: PeopleGroupInfo, dropboxStore: DropboxPhotoStore,
         assetIndex: LocalAssetIndex, peopleEngine: PeopleEngine) {
        self.group = group
        self.dropboxStore = dropboxStore
        self.peopleEngine = peopleEngine
        self.assetIndex = assetIndex
    }

    public var body: some View {
        Group {
            if let store {
                PhotoSourceContentView(store: store, title: group.name)
                    .environment(\.sourceMenuContent) { [group] in
                        AnyView(
                            Button { menuTarget = group } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel(Text(L("Group options")))
                        )
                    }
                    .peopleGroupActions(for: $menuTarget, engine: peopleEngine)
            } else {
                Color.clear.busyOverlay(true, text: L("Loading photos…"))
            }
        }
        .task {
            guard store == nil else { return }
            await reload()
        }
        // 写真ごとの汎用メニュー（「XX ではない」「別の人…」）で直したら、開いたまま描き直す
        // （PersonAlbumView と同じ。差分が無ければ組み直さない＝スクロール位置を保つ）。
        .onChange(of: peopleEngine.editVersion) { _, _ in Task { await reload() } }
    }

    @State private var members: [String] = []

    private func reload() async {
        let latest = await peopleEngine.memberRefKeys(forGroup: group.id)
        guard store == nil || latest != members else { return }
        members = latest
        let refs = latest.compactMap(PhotoRef.decode)
        store = .forMembers(localIDs: refs.compactMap(\.localIdentifier),
                            cloudPaths: refs.compactMap(\.cloudPath),
                            dropboxStore: dropboxStore, assetIndex: assetIndex)
    }
}
#endif
