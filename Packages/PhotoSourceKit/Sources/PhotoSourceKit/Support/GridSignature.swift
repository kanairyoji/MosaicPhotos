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

/// 2 つの配列が**同じ実体**（COW の同一バッファ）かを O(1) で見分ける。
///
/// ⚠️ なぜ要るか（実機 diagnostics-59）: サムネイルの密表示が重い、という報告。
/// 採取したメインスタックはグリッドを名指ししていた——
///
///     PhotoCollectionView.updateUIView
///       → Coordinator.update(items:…)
///         → gridIdentitySignature
///           → MergedPhotoItem.id.getter : Swift.String
///             → LocalPhotoItem.id.getter : Swift.String   （PHAsset.localIdentifier を読む）
///
/// 指紋は「作り直しを避けるため」に ID 列全体を混ぜる（それ自体は正しい）。しかし
/// **ズームで列数を変えるだけでも `updateUIView` は走る**ので、中身が 1 つも変わっていない
/// のに 86,000 件ぶんの文字列生成と ObjC プロパティ読み出しを毎回やり直していた。
///
/// 同一バッファなら中身は必ず等しい。違っていても中身が同じことはあり得るので、
/// **「同じ」と言えたときだけ**再計算を省く（偽陰性は安全側＝ただ計算するだけ）。
///
/// ⚠️ 比較する側は**前回の配列を保持し続ける**こと。手放すとバッファが解放され、
/// 別の配列が同じアドレスに載って「同じ」と誤判定し得る。
func sharesStorage<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    let left = lhs.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    let right = rhs.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    return left == right
}

/// 一覧の指紋（**撮影日も混ぜる**版）。スナップショットを作り直すかの判定に使う。
///
/// ⚠️ **識別子だけでは足りない**（レビュー 7 周目）。月の見出しは撮影日で決まるので、
/// 「並びは同じまま撮影日だけが直る」更新を識別子で判定すると**見出しが古いまま**残る。
/// 共有フォルダは撮影順にアップロードされることが多く、受け取った撮影日を反映しても
/// 並びは変わらない——ADR-199 がいちばん効いてほしい場面がまさにそれで、
/// ストア側の指紋に撮影日を入れても（`MergedPhotoStore.signature(of:)`）、ここで止められていた。
///
/// 撮影日の読み出しは、判定が真になった後に走る `photoGridSections` が同じぶんだけ行う。
/// 二重になるのは作り直す回だけで、桁は変わらない。
func gridContentSignature<S: Sequence>(_ items: S) -> Int where S.Element: PhotoItem {
    var hasher = Hasher()
    var count = 0
    for item in items {
        hasher.combine(item.id)
        hasher.combine(item.captureDate)
        count += 1
    }
    hasher.combine(count)   // 長さも混ぜる（前方一致を取り違えない）
    return hasher.finalize()
}
