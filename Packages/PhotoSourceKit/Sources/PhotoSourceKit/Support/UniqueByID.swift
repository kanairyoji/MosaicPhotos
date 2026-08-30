import Foundation

/// 同じ ID の項目を**先勝ちで 1 つに畳む**（並び順は保つ）。
///
/// ⚠️ グリッドの土台である `UICollectionViewDiffableDataSource` は、スナップショットに
/// 同じ識別子が 2 つ入ると **例外を投げてアプリを落とす**
/// （実機 diagnostics-69: `supplied item identifiers are not unique`）。
/// 一覧の重複はデータ側の異常（メンバー refKey → localIdentifier の重複など）だが、
/// **表示は読み取りにすぎない**ので、異常があっても落とさず出せるところまで出す
/// （ADR-143「表示のための集計が trap してはいけない」と同じ原則）。
///
/// O(n)・追加確保は Set 1 つ。68k 件でも数 ms で、オフメインの構築段で使う。
func uniquedByID<T: Identifiable>(_ items: [T]) -> [T] {
    var seen = Set<T.ID>()
    seen.reserveCapacity(items.count)
    var out: [T] = []
    out.reserveCapacity(items.count)
    for item in items where seen.insert(item.id).inserted { out.append(item) }
    return out
}

/// 文字列 ID の配列を先勝ちで一意化する（メンバー限定アルバムの ID 列の正規化用）。
public func uniquedIdentifiers(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    seen.reserveCapacity(ids.count)
    var out: [String] = []
    out.reserveCapacity(ids.count)
    for id in ids where seen.insert(id).inserted { out.append(id) }
    return out
}
