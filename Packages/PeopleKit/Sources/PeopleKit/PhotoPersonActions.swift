#if canImport(UIKit)
import AutoAlbumCore
import MosaicSupport
import PhotoSourceKit
import SwiftUI

// MARK: - どの写真ビューでも「この人は XX ではない／別の人」を出す

/// 人物アルバム**以外**の写真ビュー（AI アルバム・場所・全写真・端末アルバム…）に、
/// 「この人は XX ではない」「この人は別の人…」を付けるモディファイア。
///
/// ⚠️ 実フィードバック: 「AI アルバムで家族を束ねたグループを見ていて、**家族じゃない写真が
/// あるぞ**、という場合に使いたい」。誤りは人物アルバムだけで見つかるわけではない——
/// 見つけた場所で直せないと、覚えて画面を移動するという負担が残る。
///
/// 出すのは**1 人しか写っていない写真**に限る（`PeopleEngine.solePerson`）。複数人の写真では
/// 「どの人を直すのか」がメニューの文言で決まらないので、人物アルバム／顔の管理に任せる。
struct PhotoPersonActionsModifier: ViewModifier {
    let peopleEngine: PeopleEngine
    /// 付け替え先を選ぶ対象（写真＋いまその写真で認識されている人物）。
    @State private var pending: PendingReassign?

    /// 「別の人」を選ぶシートの対象。
    private struct PendingReassign: Identifiable, Equatable {
        let itemID: String
        let clusterID: Int
        var id: String { "\(itemID)|\(clusterID)" }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.photoContextActionProvider) { itemID in
                await actions(for: itemID)
            }
            .sheet(item: $pending) { target in
                PhotoPersonPickerView(itemID: target.itemID, currentClusterID: target.clusterID,
                                      peopleEngine: peopleEngine) { toClusterID in
                    Task {
                        let moved = await peopleEngine.movePhoto(itemID: target.itemID,
                                                                 from: target.clusterID,
                                                                 to: toClusterID)
                        Diagnostics.mark("people: moved \(moved) face(s) \(target.clusterID)→"
                                         + (toClusterID.map(String.init) ?? "new"))
                    }
                }
            }
    }

    /// この写真ぶんの操作。1 人だけ写っているときに 2 つ、それ以外は空。
    @MainActor
    private func actions(for itemID: String) async -> [PhotoContextAction] {
        guard let person = await peopleEngine.solePerson(inItem: itemID) else { return [] }
        let clusterID = person.clusterID
        return [
            PhotoContextAction(
                id: "not-this-person",
                title: L("Not “\(person.displayName)”"),
                systemImage: "person.crop.circle.badge.xmark",
                isDestructive: true
            ) { id in
                let removed = await peopleEngine.removePhoto(itemID: id, from: clusterID)
                Diagnostics.mark("people: removed \(removed) face(s) from cluster \(clusterID)")
            },
            PhotoContextAction(
                id: "someone-else",
                title: L("Someone Else…"),
                systemImage: "person.2.crop.square.stack"
            ) { id in
                pending = PendingReassign(itemID: id, clusterID: clusterID)
            }
        ]
    }
}

extension View {
    /// 写真 1 枚の人物修正（「この人は XX ではない」「別の人…」）を、この配下の写真ビュー全部に付ける。
    /// 1 人しか写っていない写真にだけ出る。人物アルバムは自前の操作を持つので上書きする。
    public func photoPersonActions(peopleEngine: PeopleEngine) -> some View {
        modifier(PhotoPersonActionsModifier(peopleEngine: peopleEngine))
    }
}
#endif
