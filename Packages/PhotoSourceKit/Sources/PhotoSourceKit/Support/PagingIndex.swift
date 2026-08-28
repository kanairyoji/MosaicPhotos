import Foundation

/// 一覧の中の「現在位置」を解く（純ロジック・テスト対象）。
///
/// ⚠️ なぜ要るか（実機 diagnostics-58）: フル画面ビューが 18 秒級のハングを繰り返し、
/// 採取したメインスレッドのスタックが犯人を名指ししていた——
///
///     PhotoPageView.currentItem.getter
///       → closure #1 (A.Item) -> Bool
///         → MergedPhotoItem.id.getter : Swift.String
///
/// `currentItem` が `items.first { $0.id == currentID }` で**毎回全件を線形走査**しており、
/// しかも `MergedPhotoItem.id` は `"L-\(item.id)"` を**呼ばれるたびに組み立てる計算プロパティ**。
/// 9 万件の一覧では 1 回の body 評価で 9 万個の String を作って捨てる。`currentItem` は
/// 上部ラベル・下部バー・お気に入り判定から複数回呼ばれるので、フレームごとに数十万回になる。
///
/// 位置（Int）を持ち回り、当たっていれば探索しない。外れたとき（一覧が入れ替わった）だけ探す。
public enum PagingIndex {

    /// `id` の位置を返す。`hint` が当たっていれば **O(1)**、外れたときだけ線形探索する。
    /// - Parameter hint: 直前に分かっていた位置（無ければ nil）。
    public static func resolve<Item: Identifiable>(_ items: [Item], id: Item.ID,
                                                   hint: Int?) -> Int? {
        if let hint, items.indices.contains(hint), items[hint].id == id { return hint }
        return items.firstIndex { $0.id == id }
    }

    /// `hint` を検証して当たっていれば要素を返す（外れたら探索）。
    public static func item<Item: Identifiable>(_ items: [Item], id: Item.ID,
                                                hint: Int?) -> Item? {
        guard let index = resolve(items, id: id, hint: hint) else { return nil }
        return items[index]
    }
}
