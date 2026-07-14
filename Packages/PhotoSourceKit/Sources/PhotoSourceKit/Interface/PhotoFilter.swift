import Foundation

/// サムネイルビュー共通のフィルタ条件（SwiftUI 非依存の値型）。
/// 全グリッドは `PhotoSourceContentView` に合流するため、ここに条件を足せば全画面に効く。
/// 現状は「お気に入りのみ」だけ。将来の条件（日付・場所など）もこの型に追加する。
public struct PhotoFilter: Equatable, Sendable {
    /// ソース（端末/クラウド）の絞り込み。
    public enum Source: String, CaseIterable, Sendable {
        case all        // 絞り込みなし
        case localOnly  // 端末写真のみ
        case cloudOnly  // クラウド（Dropbox）のみ
    }

    /// お気に入り（ハート）を付けた写真だけに絞る。
    public var favoritesOnly: Bool = false
    /// 画像のソース（端末のみ／クラウドのみ）。ピープル等の混在ビューで使う。
    public var source: Source = .all

    public init() {}

    /// 何らかの絞り込みが有効か（フィルタボタンの強調表示に使う）。
    public var isActive: Bool { favoritesOnly || source != .all }

    /// アイテム列へフィルタを適用する（未フィルタなら配列をそのまま返す）。
    public func apply<Item: PhotoItem>(_ items: [Item]) -> [Item] {
        guard isActive else { return items }
        return items.filter { item in
            if favoritesOnly && !item.isFavorite { return false }
            switch source {
            case .all:       return true
            case .localOnly: return !item.isCloudSource
            case .cloudOnly: return item.isCloudSource
            }
        }
    }
}
