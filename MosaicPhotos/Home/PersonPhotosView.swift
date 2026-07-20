import AutoAlbumCore
import SwiftUI

/// 顔の管理シート。この人物として認識した顔の切り抜きを並べ（複数人の写真でもどの顔か分かる）、
/// タップで「この顔は別の人」→ 正しい人物へ付け替えできる。
/// ※ 写真の閲覧（フル画面・EXIF/場所の上スワイプ）は通常ビューア（人物タップ）を使う。ここは管理専用。
struct PersonPhotosView: View {
    let person: PersonInfo
    let peopleEngine: PeopleEngine

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [PersonInfo.Face] = []
    @State private var reassignFace: PersonInfo.Face?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]

    var body: some View {
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

/// 人物アルバムの統合先を選ぶピッカー。`source` を選んだ人物へまとめる（同一人物が 2 つに
/// 割れたときの修正）。統合は元に戻せないので、選択時に確認アラートを挟む。
struct PersonMergePickerView: View {
    let source: PersonInfo
    let peopleEngine: PeopleEngine

    @Environment(\.dismiss) private var dismiss
    @State private var pendingTarget: PersonInfo?

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
                    Text(L("Choose the person to merge “\(source.displayName)” into. All their photos will move to that person."))
                }
                Section(L("Merge into")) {
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
            .navigationTitle(L("Merge Person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .alert(L("Merge people?"), isPresented: Binding(get: { pendingTarget != nil },
                                                            set: { if !$0 { pendingTarget = nil } }),
                   presenting: pendingTarget) { target in
                Button(L("Cancel"), role: .cancel) { pendingTarget = nil }
                Button(L("Merge")) {
                    let src = source.clusterID, dst = target.clusterID
                    Task {
                        await peopleEngine.mergePerson(from: src, into: dst)
                        dismiss()
                    }
                }
            } message: { target in
                Text(L("“\(source.displayName)” will be merged into “\(target.displayName)”. This can’t be undone automatically."))
            }
        }
    }
}
