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
    private static let lock = NSLock()
    private static var next: [String: Int] = [:]

    /// `label` ごとに `label-0`, `label-1`, … を**使い回さずに**順に配る。
    ///
    /// ⚠️ **番号を折り返さない**（レビュー 8 周目）。上限 32 で折り返していたが、
    /// 実際の配布数がちょうど 32 で余裕ゼロだった。テストを 1 本足した瞬間に 33 本目が
    /// `label-0` を受け取り、**まだ使っている 1 本目の中身を消す**——この仕組みが
    /// 防ぐはずだった取り合いが戻る。しかも割り当ては実行順に依存するので再現しない。
    ///
    /// 折り返さなければ、1 回の実行の中で同じ名前が二度配られることは決して無い。
    /// ファイルの数は「1 回の実行の配布数」で頭打ちになる（＝増え続けない）ので、
    /// 上限を設ける目的は果たせている。
    static func scratch(_ label: String) -> UserDefaults {
        lock.lock()
        let index = next[label] ?? 0
        next[label] = index + 1
        lock.unlock()
        let name = "\(label)-\(index)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)   // 前回の実行の残りを消してから始める
        return defaults
    }
}
