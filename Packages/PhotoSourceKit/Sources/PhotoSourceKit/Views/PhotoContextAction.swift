#if canImport(UIKit)
import Foundation

/// 写真 1 枚に対する追加操作（グリッドの長押しメニュー・全画面のメニューに出る）。
///
/// ⚠️ 実フィードバック: 「ピープルアルバムのサムネイル／全画面から『この写真はこの人ではない』を
/// 呼べるようにして。**全体像や前後関係で違うと気づく**ことがある」。顔だけを並べた
/// 「顔の管理」では、その気づき方ができない——だから写真を見ている場所から直接直せるようにする。
///
/// `PhotoSourceKit` は顔の仕組みを知らないので、**表示名と実行**を呼び出し側から受け取る。
public struct PhotoContextAction: Identifiable, Sendable {
    public let id: String
    /// メニューに出す文言（例: 「この写真は太郎さんではない」）。
    public let title: String
    public let systemImage: String
    /// 破壊的な操作として赤字で出すか（人物から外す＝取り消しづらい）。
    public let isDestructive: Bool
    /// 実行（引数は写真の ID＝`PhotoItem.id`）。
    public let perform: @MainActor @Sendable (String) async -> Void

    public init(id: String, title: String, systemImage: String,
                isDestructive: Bool = false,
                perform: @escaping @MainActor @Sendable (String) async -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.perform = perform
    }
}
#endif
