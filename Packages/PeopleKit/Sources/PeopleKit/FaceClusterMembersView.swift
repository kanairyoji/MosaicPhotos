#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// 近傍の人物として認識している顔の一覧（デバッグ・読み取り専用）。
/// 「この人物は実際に誰の顔で出来ているのか」を確かめる用。
struct FaceClusterMembersView: View {
    let clusterID: Int
    let title: String
    /// 調査対象のクラスタ ID（重なりの照合に使う）。
    let focusClusterID: Int
    /// 調査対象の表示名（「この人物は◯◯」の◯◯）。
    let focusName: String
    let peopleEngine: PeopleEngine
    /// 顔の切り抜き／写真全体の切り替え（親と共有する）。
    @Binding var showsWholePhoto: Bool
    /// この人物を内訳の対象に切り替える。
    let onFocus: (Int) -> Void
    /// この人物を調査対象の人物へ統合する。
    let onMerge: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [PersonInfo.Face] = []
    /// 「別の人へ移す」対象（顔のタップ）。
    @State private var reassignTarget: PersonInfo.Face?
    @State private var confirmingMerge = false
    /// 同じ写真に一緒に写っている箇所（＝統合できない理由）。
    @State private var conflicts: [(refKey: String, first: PersonInfo.Face, second: PersonInfo.Face)] = []

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 3)]

    var body: some View {
        ScrollView {
            if !conflicts.isEmpty { conflictSection }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(faces) { face in
                    // タップで正しい人物へ移せる（誤りに気づく場所は 1 つではない・ADR-137）。
                    Button { reassignTarget = face } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                FaceAvatarImage(refKey: face.refKey,
                                                box: showsWholePhoto ? nil : face.boundingBox,
                                                maxPixel: 320,
                                                contentMode: showsWholePhoto ? .fit : .fill)
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .navigationTitle("\(title)（\(faces.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsWholePhoto.toggle() } label: {
                    Image(systemName: showsWholePhoto ? "person.crop.square" : "photo")
                }
                .accessibilityLabel(Text(showsWholePhoto ? L("Show face") : L("Show whole photo")))
            }
        }
        // ⚠️ 「対象にする」だけでは**何の対象か分からない**（実フィードバック）。
        // 何が起きるかを書いた**フル幅のボタン**にする（ツールバーだと長い名前が入らない）。
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                // ⚠️ 顔を見て「これは調査対象の本人だった」と分かる場面が本題（実フィードバック）。
                // その判断をこの場で確定できるようにする（一覧の左スワイプ・長押しと同じ操作）。
                Button {
                    confirmingMerge = true
                } label: {
                    Label(L("This is “\(focusName)”"), systemImage: "person.2.slash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    onFocus(clusterID)
                    dismiss()
                } label: {
                    Label(L("Inspect this person instead"), systemImage: "scope")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                Text(L("Top: combine this person into “\(focusName)”. Bottom: switch the inspection to this person."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .alert(L("Combine “\(title)” into “\(focusName)”?"), isPresented: $confirmingMerge) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Combine")) { onMerge(); dismiss() }
        } message: {
            Text(L("\(faces.count) faces will move into “\(focusName)”. If it turns out to be wrong, you can fix it from Manage Faces."))
        }
        .task {
            faces = await peopleEngine.coverCandidates(clusterID: clusterID)
            await reloadConflicts()
        }
        .sheet(item: $reassignTarget) { face in
            FaceReassignPickerView(faceID: face.faceID, refKey: face.refKey,
                                   boundingBox: face.boundingBox,
                                   currentClusterID: clusterID,
                                   peopleEngine: peopleEngine) { target in
                Task {
                    await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: target)
                    faces = await peopleEngine.coverCandidates(clusterID: clusterID)
                }
            }
        }
    }

    /// 「同じ写真に一緒に写っている」ので統合できない箇所を出す（ADR-146）。
    ///
    /// ⚠️ 1 枚に同じ人は 1 回しか写れない——が、**重複検出・写真の中の写真・鏡**では破れる。
    /// 破れているとユーザーは統合できず、しかも**どの写真が原因か分からない**（実フィードバック）。
    /// 写真と両方の顔を並べ、その場で片方を外せるようにする。
    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Photos where both appear"))
                .font(.subheadline.weight(.semibold))
            Text(L("These photos contain a face of “\(focusName)” and a face of this person, so they can’t be the same person. If the same face was picked up twice, remove one of them."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(conflicts, id: \.refKey) { conflict in
                conflictRow(conflict)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func conflictRow(
        _ conflict: (refKey: String, first: PersonInfo.Face, second: PersonInfo.Face)
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 写真全体（box なし）＝どの写真かが分かる。
                FaceAvatarImage(refKey: conflict.refKey, box: nil, maxPixel: 300)
                    .frame(width: 76, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                conflictFace(conflict.first, caption: focusName)
                conflictFace(conflict.second, caption: title)
            }
            HStack(spacing: 8) {
                Button(L("Remove the “\(focusName)” face")) { remove(conflict.first) }
                    .buttonStyle(.bordered).font(.caption)
                Button(L("Remove the “\(title)” face")) { remove(conflict.second) }
                    .buttonStyle(.bordered).font(.caption)
            }
        }
    }

    private func conflictFace(_ face: PersonInfo.Face, caption: String) -> some View {
        VStack(spacing: 2) {
            FaceAvatarImage(refKey: face.refKey,
                            box: showsWholePhoto ? nil : face.boundingBox, maxPixel: 200,
                            contentMode: showsWholePhoto ? .fit : .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 重なっている顔の片方を人物から外す（新しい人物になる）。外れれば統合できる。
    private func remove(_ face: PersonInfo.Face) {
        Task {
            await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: nil)
            faces = await peopleEngine.coverCandidates(clusterID: clusterID)
            await reloadConflicts()
        }
    }

    private func reloadConflicts() async {
        guard focusClusterID >= 0, focusClusterID != clusterID else { conflicts = []; return }
        conflicts = await peopleEngine.samePhotoConflicts(between: focusClusterID, and: clusterID)
    }

}
#endif
