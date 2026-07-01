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
                Text(L("Tap a face that isn’t this person to move it to the correct person."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(faces) { face in
                        Button { reassignFace = face } label: { FaceTile(face: face) }
                            .buttonStyle(.plain)
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
}

/// この人物として認識した顔の切り抜き（正方タイル）。
private struct FaceTile: View {
    let face: PersonInfo.Face
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)   // 列幅ぴったりの正方形にする
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: face.id) {
                image = await loadFaceAvatar(coverRefKey: face.refKey, box: face.boundingBox, maxPixel: 320)
            }
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
    @State private var faceImage: UIImage?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(Color(uiColor: .secondarySystemBackground))
                            if let faceImage { Image(uiImage: faceImage).resizable().scaledToFill() }
                        }
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
                        Label(L("New person"), systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Section(L("Choose the correct person")) {
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
            .task(id: face.id) {
                faceImage = await loadFaceAvatar(coverRefKey: face.refKey, box: face.boundingBox, maxPixel: 320)
            }
        }
    }
}

private struct ReassignAvatar: View {
    let person: PersonInfo
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .task(id: person.coverRefKey ?? "\(person.id)") {
            image = await loadFaceAvatar(coverRefKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 200)
        }
    }
}
