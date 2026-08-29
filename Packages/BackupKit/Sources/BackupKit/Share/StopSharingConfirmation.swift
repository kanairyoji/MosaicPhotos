#if canImport(UIKit)
import SwiftUI

// MARK: - クラウド共有の停止（共有元から）
//
// ⚠️ もとはアプリターゲットに居たが、共有元は**アルバム・人物・グループ**の 3 か所にあり、
// 人物とグループの UI は `PeopleKit` へ出た。停止の確認ダイアログは共有そのものの UI なので、
// `ShareSyncEngine` と同じパッケージ（BackupKit）に置く。

/// 停止対象の共有セット。共有元（人物 / グループ / アルバム）のメニューから渡す。
public struct StopSharingTarget: Identifiable {
    public let setID: UUID
    public let name: String
    public var id: UUID { setID }

    public init(setID: UUID, name: String) {
        self.setID = setID
        self.name = name
    }
}

/// 「クラウド共有を停止」の確認ダイアログ。
///
/// 停止＝**共有フォルダごと削除**する。共有元（人物・アルバム）も、端末写真も、
/// バックアップも消えない——ここを取り違えると怖くて押せないので、文言で明示する。
/// 相手が既に保存した写真は取り消せない点も併せて伝える。
private struct StopSharingConfirmation: ViewModifier {
    @Binding var target: StopSharingTarget?
    let shareEngine: ShareSyncEngine?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L("Stop cloud sharing? The folder is removed from your shared area, so people you share with will no longer see these photos. Copies they already saved can't be removed. The album or person, your photos, and your backup are all kept."),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible, presenting: target
        ) { item in
            Button(L("Stop Sharing"), role: .destructive) {
                guard let shareEngine else { return }
                // 停止はフォルダ削除の往復を伴う。UI は待たせず、完了は共有バッジが消えて伝わる。
                Task { await shareEngine.stopSharing(setID: item.setID) }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

extension View {
    public func stopSharingConfirmation(_ target: Binding<StopSharingTarget?>,
                                 shareEngine: ShareSyncEngine?) -> some View {
        modifier(StopSharingConfirmation(target: target, shareEngine: shareEngine))
    }
}
#endif
