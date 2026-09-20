import Foundation

/// テスト用の使い捨て `UserDefaults`。
///
/// ⚠️ **名前に UUID を使わない**（レビュー 7 周目）。`UserDefaults(suiteName:)` は
/// `~/Library/Preferences` にファイルを作り、`removePersistentDomain` は**中身を消すだけ**で
/// ファイルは残る。UUID の名前だと実行のたびに新しいファイルが増え続ける
/// ——実測で 11,447 個まで育ち、`swift test` 1 回あたり +43 個だった。
///
/// 名前を**有限のプールから配る**と上限ができる。並行して走るテストどうしは違う名前を受け取り、
/// 実行をまたぐと同じ名前を使い回す（開始時に中身を消すので前回の残りは効かない）。
enum TestDefaults {
    /// 1 つの用途につき用意する名前の数。並行して走るテストの数より十分多ければよい。
    static let poolSize = 32

    private static let lock = NSLock()
    private static var next: [String: Int] = [:]

    /// `label` ごとに `label-0` … `label-31` を順に配る。
    static func scratch(_ label: String) -> UserDefaults {
        lock.lock()
        let index = (next[label] ?? 0) % poolSize
        next[label] = index + 1
        lock.unlock()
        let name = "\(label)-\(index)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)   // 前回の残りを消してから始める
        return defaults
    }
}
