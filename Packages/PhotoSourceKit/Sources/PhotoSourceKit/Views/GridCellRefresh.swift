import Foundation

/// 構成が変わらない更新（同じ ID 列）で、表示中のセルを**作り直す必要があるか**（純ロジック・テスト対象）。
///
/// ⚠️ 判断はここだけに置く（グリッドが呼ぶ）。以前はグリッドの中で `isFavorite` だけを比べていたので、
/// 長さが後から分かった動画（ADR-282・1 本ずつ問い合わせて埋まる）はセルが作り直されず、
/// スクロールするまで動画の印が残っていた。セルの見た目に効く項目を足したら、ここにも足す。
enum GridCellRefresh {
    static func needsReconfigure<Item: PhotoItem>(old: Item, new: Item) -> Bool {
        old.isFavorite != new.isFavorite || old.videoDuration != new.videoDuration
    }
}
