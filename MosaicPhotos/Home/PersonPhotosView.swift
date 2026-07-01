import AutoAlbumCore
import PhotoSourceKit
import SwiftUI

/// ピープル（顔クラスタ）の写真一覧。1 枚ごとに「この人物として認識した顔」の切り抜きを並べ、
/// タップで元写真＋認識した顔の枠を表示。そこから「この人は別の人」で正しい人物へ付け替えできる。
struct PersonPhotosView: View {
    let person: PersonInfo
    let peopleEngine: PeopleEngine

    @Environment(\.dismissToHome) private var dismissToHome
    @State private var faces: [PersonInfo.Face] = []
    @State private var detailFace: PersonInfo.Face?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(faces) { face in
                        Button { detailFace = face } label: { FaceTile(face: face) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(3)
            }
            .navigationTitle(person.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismissToHome?() } label: { Image(systemName: "house") }
                        .accessibilityLabel(L("Home"))
                }
            }
            .task(id: person.clusterID) {
                faces = await peopleEngine.coverCandidates(clusterID: person.clusterID)
            }
            .sheet(item: $detailFace) { face in
                PersonFaceDetailView(face: face, person: person, peopleEngine: peopleEngine) {
                    // 付け替え後：この人物から外れた顔を除いて一覧を更新。
                    faces = await peopleEngine.coverCandidates(clusterID: person.clusterID)
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

// MARK: - Detail (元写真＋認識した顔の枠＋別人指定)

/// 元写真に「認識した顔」の枠を重ねて表示し、「この人は別の人」で正しい人物へ付け替える。
struct PersonFaceDetailView: View {
    let face: PersonInfo.Face
    let person: PersonInfo
    let peopleEngine: PeopleEngine
    let onReassigned: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var showReassign = false
    /// 顔の枠表示トグル（既定 OFF＝普通に画像を表示）。Person ビューから入ったこの画面だけの機能。
    @State private var showFaceBox = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    PhotoWithFaceBox(image: image, box: face.boundingBox, showBox: showFaceBox)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(person.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                    // 戻る（Done）の横に「顔表示」トグル。ON で認識した顔に枠を出す。
                    Button { showFaceBox.toggle() } label: {
                        Image(systemName: showFaceBox ? "viewfinder.circle.fill" : "viewfinder")
                    }
                    .accessibilityLabel(L("Show face"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Not this person")) { showReassign = true }
                }
            }
            .task(id: face.id) {
                image = await loadLocalAspectImage(refKey: face.refKey, maxPixel: 1200)
            }
            .sheet(isPresented: $showReassign) {
                ReassignPickerView(currentClusterID: person.clusterID, peopleEngine: peopleEngine) { targetClusterID in
                    Task {
                        await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: targetClusterID)
                        await onReassigned()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 画像を aspectFit で表示し、認識した顔（Vision 正規化・原点左下）の位置に黄枠を重ねる。
/// ★ 画像と枠を**同じ描画矩形 `fit`** に載せることで位置ズレを防ぐ（以前は画像が左上寄せなのに
///   枠は中央寄せ前提で計算していてズレていた）。
private struct PhotoWithFaceBox: View {
    let image: UIImage
    let box: CGRect   // 正規化・原点左下
    let showBox: Bool

    var body: some View {
        GeometryReader { geo in
            let fit = Self.aspectFitRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                // 画像は fit の位置・サイズに明示的に置く（GeometryReader/ZStack の既定配置に依存しない）。
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                if showBox {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: box.width * fit.width, height: box.height * fit.height)
                        .offset(x: fit.minX + box.minX * fit.width,
                                y: fit.minY + (1 - box.minY - box.height) * fit.height)   // y 反転
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// `imageSize` を `container` に aspectFit したときの描画矩形（レターボックス込み）。
    static func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Reassign picker（正しい人物を選ばせる）

/// 「この人は別の人」で正しい人物を選ぶ。既存の人物一覧＋「新しい人物」。
private struct ReassignPickerView: View {
    let currentClusterID: Int
    let peopleEngine: PeopleEngine
    /// 選択されたクラスタ ID（nil＝新しい人物）。
    let onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        Label(L("New person"), systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Section(L("Choose the correct person")) {
                    ForEach(peopleEngine.people.filter { $0.clusterID != currentClusterID }) { p in
                        Button {
                            onPick(p.clusterID)
                            dismiss()
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
