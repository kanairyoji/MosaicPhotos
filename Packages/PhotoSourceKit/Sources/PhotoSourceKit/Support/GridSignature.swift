import Foundation

/// グリッド構成の指紋（純ロジック・テスト対象）。
///
/// ⚠️ **ID 列全体**から作ること。件数と両端だけの指紋では、件数が同じまま中間が
/// 入れ替わった変化（1 枚消えて 1 枚増えた・並び替え）を取りこぼす。取りこぼすと
/// `PhotoCollectionView` は snapshot / `idToIndex` を作り直さないまま `items` だけ
/// 差し替えるため、**別の写真が表示され、タップ時の ID も食い違う**（レビュー指摘）。
///
/// `Hasher` の種はプロセスごとに変わるが、比較はプロセス内で完結するので問題ない。
func gridIdentitySignature<S: Sequence>(_ ids: S) -> Int where S.Element: Hashable {
    var hasher = Hasher()
    var count = 0
    for id in ids {
        hasher.combine(id)
        count += 1
    }
    hasher.combine(count)   // 長さも混ぜる（前方一致の取り違えを防ぐ）
    return hasher.finalize()
}
