#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// 顔の管理シート。この人物として認識した顔の切り抜きを並べ（複数人の写真でもどの顔か分かる）、
/// タップで「この顔は別の人」→ 正しい人物へ付け替えできる。
/// ※ 写真の閲覧（フル画面・EXIF/場所の上スワイプ）は通常ビューア（人物タップ）を使う。ここは管理専用。
public struct PersonPhotosView: View {
    public let person: PersonInfo
    public let peopleEngine: PeopleEngine

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [PersonInfo.Face] = []
    @State private var reassignFace: PersonInfo.Face?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]


    public init(person: PersonInfo, peopleEngine: PeopleEngine) {
        self.person = person
        self.peopleEngine = peopleEngine
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(L("Tap a face that isn’t this person. Choose “Not this person” to just remove it, or pick the correct person."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(faces) { face in
                        // タップ＝正しい人物を選ぶ／長押し＝相手を選ばず「別の人」として外す。
                        Button { reassignFace = face } label: { FaceTile(face: face) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    removeFace(face)
                                } label: {
                                    Label(L("Not this person"), systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                    }
                }
                .padding(3)
            }
            .navigationTitle(person.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .task(id: person.clusterID) {
                faces = await peopleEngine.coverCandidates(clusterID: person.clusterID)
            }
            .sheet(item: $reassignFace) { face in
                ReassignPickerView(face: face, currentClusterID: person.clusterID, peopleEngine: peopleEngine) { targetClusterID in
                    Task {
                        await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: targetClusterID)
                        faces = await peopleEngine.coverCandidates(clusterID: person.clusterID)
                    }
                }
            }
        }
    }

    /// 相手を選ばず「この人ではない」として外す（新規クラスタへ分離）。
    /// ADR-45: これは負例（この顔 ≠ この人物）として学習され、再発を防ぐ。
    private func removeFace(_ face: PersonInfo.Face) {
        Task {
            await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: nil)
            faces = await peopleEngine.coverCandidates(clusterID: person.clusterID)
        }
    }
}

/// この人物として認識した顔の切り抜き（正方タイル）。
private struct FaceTile: View {
    let face: PersonInfo.Face

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)   // 列幅ぴったりの正方形にする
            .overlay { FaceAvatarImage(refKey: face.refKey, box: face.boundingBox, maxPixel: 320) }
            .clipped()
    }
}

// MARK: - Reassign picker（正しい人物を選ばせる）

/// 「この人は別の人」で正しい人物を選ぶ。上部に対象の顔を出し、既存の人物一覧＋「新しい人物」から選ぶ。
private struct ReassignPickerView: View {
    let face: PersonInfo.Face
    let currentClusterID: Int
    let peopleEngine: PeopleEngine
    /// 選択されたクラスタ ID（nil＝新しい人物）。
    let onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        FaceAvatarImage(refKey: face.refKey, box: face.boundingBox, maxPixel: 320)
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        onPick(nil); dismiss()
                    } label: {
                        Label(L("Not this person (don’t pick anyone)"),
                              systemImage: "person.crop.circle.badge.xmark")
                    }
                } footer: {
                    Text(L("Removes this face from the person. It becomes its own new person; the app learns from this so the mistake isn’t repeated."))
                }
                Section(L("Or choose the correct person")) {
                    ForEach(peopleEngine.people.filter { $0.clusterID != currentClusterID }) { p in
                        Button {
                            onPick(p.clusterID); dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ReassignAvatar(person: p)
                                Text(p.displayName).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Not this person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct ReassignAvatar: View {
    let person: PersonInfo
    var body: some View {
        FaceAvatarImage(refKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 200)
            .frame(width: 40, height: 40)
            .clipShape(Circle())
    }
}

// MARK: - Merge people

/// 人物の束ね先を選ぶピッカー。`source` を選んだ人物と「同じ人（成長で分裂）」として束ねる。
/// 融合せず純度を保ち、後で解除できる（ADR-61）。選択時に確認アラートを挟む。
struct PersonMergePickerView: View {
    let source: PersonInfo
    let peopleEngine: PeopleEngine

    @Environment(\.dismiss) private var dismiss
    @State private var pendingTarget: PersonInfo?
    /// 両方に名前が付いていたときの確認（ADR-94）。どちらの名前を残すか選ばせ、
    /// 「やめる」も出す（そもそも別人を束ねようとしている可能性が高いため）。
    @State private var nameChoice: NameChoice?

    /// 名前が衝突したときの確認内容。
    private struct NameChoice: Identifiable {
        let id = UUID()
        let clusterIDs: [Int]
        let names: [String]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            ReassignAvatar(person: source)
                                .frame(width: 72, height: 72)
                            Text(source.displayName).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(L("Choose the person to group “\(source.displayName)” with as the same person (e.g. a child across ages). Their photos will appear together. You can separate them later."))
                }
                Section(L("Group with")) {
                    ForEach(peopleEngine.people.filter { $0.clusterID != source.clusterID }) { p in
                        Button {
                            pendingTarget = p
                        } label: {
                            HStack(spacing: 12) {
                                ReassignAvatar(person: p)
                                Text(p.displayName).foregroundStyle(.primary)
                                Spacer()
                                Text(L("\(p.count) photos")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Group as Same Person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .alert(L("Group as same person?"), isPresented: Binding(get: { pendingTarget != nil },
                                                            set: { if !$0 { pendingTarget = nil } }),
                   presenting: pendingTarget) { target in
                Button(L("Cancel"), role: .cancel) { pendingTarget = nil }
                Button(L("Group")) {
                    let src = source.clusterID, dst = target.clusterID
                    Task {
                        // 両方に名前があるなら、どちらを残すか尋ねてから束ねる（ADR-94）。
                        let names = await peopleEngine.conflictingNames([src, dst])
                        if names.count >= 2 {
                            nameChoice = NameChoice(clusterIDs: [src, dst], names: names)
                        } else {
                            await peopleEngine.linkPeople([src, dst])
                            dismiss()
                        }
                    }
                }
            } message: { target in
                Text(L("“\(source.displayName)” and “\(target.displayName)” will be shown as the same person. You can separate them later."))
            }
            // 別々の名前が付いている＝**別人を束ねようとしている可能性が高い**。
            // どちらの名前を残すか選ばせつつ、「やめる」を目立つ位置（destructive）に出す。
            .confirmationDialog(L("These people have different names"),
                                isPresented: Binding(get: { nameChoice != nil },
                                                     set: { if !$0 { nameChoice = nil } }),
                                titleVisibility: .visible,
                                presenting: nameChoice) { choice in
                ForEach(choice.names, id: \.self) { name in
                    Button(L("Keep “\(name)”")) {
                        Task {
                            await peopleEngine.linkPeople(choice.clusterIDs, keepingName: name)
                            nameChoice = nil
                            dismiss()
                        }
                    }
                }
                Button(L("Don’t group — these are different people"), role: .destructive) {
                    nameChoice = nil
                    pendingTarget = nil
                }
                Button(L("Cancel"), role: .cancel) { nameChoice = nil }
            } message: { choice in
                Text(L("Both already have names (\(choice.names.joined(separator: " / "))). Grouping keeps one name for all their photos. If they are different people, stop here."))
            }
        }
    }
}
#endif
