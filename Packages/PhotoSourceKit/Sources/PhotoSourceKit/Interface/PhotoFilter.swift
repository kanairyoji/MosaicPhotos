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
    /// ベストショット（美的スコアが高い写真）だけに絞る。判定は `apply` の `isBeautiful` で
    /// 注入する（台帳の集合はアプリ側が持つ＝PhotoSourceKit は AutoAlbumCore に依存しない）。
    public var beautifulOnly: Bool = false
    /// 画像のソース（端末のみ／クラウドのみ）。ピープル等の混在ビューで使う。
    public var source: Source = .all

    public init() {}

    /// 何らかの絞り込みが有効か（フィルタボタンの強調表示に使う）。
    public var isActive: Bool { favoritesOnly || beautifulOnly || source != .all }

    /// アイテム列へフィルタを適用する（未フィルタなら配列をそのまま返す）。
    /// - Parameter isBeautiful: ベストショット判定（`beautifulOnly` のときだけ使う）。
    ///   nil＝判定集合の読み込み中/未提供は素通し（空のグリッドで固まって見せない）。
    public func apply<Item: PhotoItem>(_ items: [Item],
                                       isBeautiful: ((Item) -> Bool)? = nil) -> [Item] {
        guard isActive else { return items }
        return items.filter { item in
            if favoritesOnly && !item.isFavorite { return false }
            if beautifulOnly, let isBeautiful, !isBeautiful(item) { return false }
            switch source {
            case .all:       return true
            case .localOnly: return !item.isCloudSource
            case .cloudOnly: return item.isCloudSource
            }
        }
    }
}
