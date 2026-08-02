import Foundation

/// 解析（顔スキャン・CLIP 埋め込み・シーンタグ等）の**処理順**を決める純ロジック。
///
/// 方針（ユーザー要望）: **お気に入りを先に**（ローカル→Dropbox）→ **その他**（ローカル→Dropbox）、
/// 各群の中は**新→古**（撮影日降順）。お気に入り＝ユーザーが大事にしている写真から先に反映される。
///
/// 入力 `refKeys` は「各群内で既に新→古に並んでいる」前提（各パスの列挙が撮影日降順のため）。
/// ここでは群（お気に入り/ローカルの 4 区分）で**安定に**並べ替えるだけ＝群内の新→古は維持する。
public enum AnalysisOrder {
    /// 群インデックス（若いほど先に処理）: 0=お気に入り×ローカル 1=お気に入り×クラウド
    /// 2=その他×ローカル 3=その他×クラウド。ローカル/クラウドは refKey の "L-"/"C-" で判定。
    public static func groupIndex(_ refKey: String, favorites: Set<String>) -> Int {
        let favBase = favorites.contains(refKey) ? 0 : 2
        let cloudOffset = refKey.hasPrefix("L-") ? 0 : 1
        return favBase + cloudOffset
    }

    /// 既に新→古で並んだ `refKeys` を、お気に入り/ローカルの 4 群で**安定に**並べ替える
    /// （群内の新→古の順序は維持）。
    public static func ordered(_ refKeys: [String], favorites: Set<String>) -> [String] {
        guard !favorites.isEmpty else {
            // お気に入りが無ければ「ローカル→クラウド（各新→古）」の 2 群だけ安定に分ける。
            return refKeys.enumerated()
                .sorted { a, b in
                    let ga = a.element.hasPrefix("L-") ? 0 : 1
                    let gb = b.element.hasPrefix("L-") ? 0 : 1
                    return ga != gb ? ga < gb : a.offset < b.offset
                }
                .map(\.element)
        }
        return refKeys.enumerated()
            .sorted { a, b in
                let ga = groupIndex(a.element, favorites: favorites)
                let gb = groupIndex(b.element, favorites: favorites)
                return ga != gb ? ga < gb : a.offset < b.offset   // 群が同じなら元の順（新→古）を維持
            }
            .map(\.element)
    }
}
