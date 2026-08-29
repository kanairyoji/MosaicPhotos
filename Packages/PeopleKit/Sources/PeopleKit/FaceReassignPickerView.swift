#if canImport(UIKit)
import AutoAlbumCore
import CoreGraphics
import SwiftUI

// MARK: - 付け替え先の人物を選ぶ（共有部品）
//
// ⚠️ 「顔の管理」だけの部品ではない（ADR-137）。実フィードバック:
// 「近傍や間違い候補の画像一覧からも『別の人』を呼び出して、正しいピープルアルバムへ
//  入れられるようにしてほしい」。誤りに気づく場所は 1 つではないので、直す入口も 1 つにしない。

/// 「この人は別の人」で正しい人物を選ぶ。上部に対象の顔を出し、既存の人物一覧＋「新しい人物」から選ぶ。
public struct FaceReassignPickerView: View {
    public let faceID: String
    public let refKey: String
    public let boundingBox: CGRect
    public let currentClusterID: Int
    public let peopleEngine: PeopleEngine
    /// 選択されたクラスタ ID（nil＝新しい人物）。
    public let onPick: (Int?) -> Void

    public init(faceID: String, refKey: String, boundingBox: CGRect, currentClusterID: Int,
                peopleEngine: PeopleEngine, onPick: @escaping (Int?) -> Void) {
        self.faceID = faceID
        self.refKey = refKey
        self.boundingBox = boundingBox
        self.currentClusterID = currentClusterID
        self.peopleEngine = peopleEngine
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        FaceAvatarImage(refKey: refKey, box: boundingBox, maxPixel: 320)
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


/// 人物の代表顔（円形の小さなアバター）。
struct ReassignAvatar: View {
    let person: PersonInfo
    var body: some View {
        FaceAvatarImage(refKey: person.coverRefKey, box: person.coverBoundingBox, maxPixel: 200)
            .frame(width: 40, height: 40)
            .clipShape(Circle())
    }
}
#endif
