import AutoAlbumCore
import SwiftUI

/// ピープル（顔クラスタ）の代表写真＝トップに出す顔を選ぶピッカー。
/// クラスタ内の顔候補（写真ごと）を円形の顔切り抜きで並べ、タップで cover に設定する。
struct PersonCoverPickerView: View {
    let person: PersonInfo
    let peopleEngine: PeopleEngine
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [PersonInfo.Face] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    Text(L("No photos for this person."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(candidates) { face in
                                Button {
                                    Task {
                                        await peopleEngine.setCover(clusterID: person.clusterID, faceID: face.faceID)
                                        dismiss()
                                    }
                                } label: {
                                    CoverCandidateAvatar(face: face,
                                                         isCurrent: face.refKey == person.coverRefKey)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(L("Choose Cover"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .task {
                candidates = await peopleEngine.coverCandidates(clusterID: person.clusterID)
                loaded = true
            }
        }
    }
}

/// 顔切り抜きの円形アバター（現在の代表には枠を付ける）。
private struct CoverCandidateAvatar: View {
    let face: PersonInfo.Face
    let isCurrent: Bool
    @State private var image: UIImage?
    private static let side: CGFloat = 84

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(Circle())
        .overlay {
            if isCurrent {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .task(id: face.id) {
            image = await loadFaceAvatar(coverRefKey: face.refKey, box: face.boundingBox, maxPixel: 400)
        }
    }
}
