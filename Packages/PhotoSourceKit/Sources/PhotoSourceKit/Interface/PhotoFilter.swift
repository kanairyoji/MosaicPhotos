import Foundation

/// サムネイルビュー共通のフィルタ条件（SwiftUI 非依存の値型）。
/// 全グリッドは `PhotoSourceContentView` に合流するため、ここに条件を足せば全画面に効く。
/// 現状は「お気に入りのみ」だけ。将来の条件（日付・場所など）もこの型に追加する。
public struct PhotoFilter: Equatable, Sendable {
    /// お気に入り（ハート）を付けた写真だけに絞る。
    public var favoritesOnly: Bool = false

    public init() {}

    /// 何らかの絞り込みが有効か（フィルタボタンの強調表示に使う）。
    public var isActive: Bool { favoritesOnly }

    /// アイテム列へフィルタを適用する（未フィルタなら配列をそのまま返す）。
    public func apply<Item: PhotoItem>(_ items: [Item]) -> [Item] {
        guard isActive else { return items }
        return items.filter { !favoritesOnly || $0.isFavorite }
    }
}
