import Foundation

/// 「そのパスにバックアップメタデータが存在しない」ことの記録（ADR-82）。
///
/// バックアップを使っていないユーザーは v1 `metadata.json` とカタログの計 4 パスがどれも存在せず、
/// `files/get_metadata` が 409 を返すまで **1 回 2.8〜3.3 秒**かかっていた（実機ログ diagnostics-32）。
/// これを毎起動 4 回繰り返していたため、不在を覚えて TTL 内は問い合わせない。
///
/// ⚠️ **UIKit ゲートの外**に置く。`DropboxPhotoStore` は `#if canImport(UIKit)` の中にあるが、
/// 無効化は `BackupKit`（macOS テストでもコンパイルされる）から呼ぶ必要があるため。
public enum BackupMetadataAbsence {
    /// UserDefaults キーの接頭辞。
    static let keyPrefix = "backupMetaAbsent:"
    /// 不在記録の有効期間。他端末がバックアップを書いた場合でも、この時間内には気づく。
    /// アプリ内でバックアップした場合は `invalidateAll()` で即座に無効化される。
    static let ttl: TimeInterval = 24 * 60 * 60

    private static func key(for path: String) -> String { keyPrefix + path.lowercased() }

    /// 記録された不在がまだ有効か（true＝問い合わせを省いてよい）。
    static func isAbsent(path: String, defaults: UserDefaults = .standard) -> Bool {
        guard let stamp = defaults.object(forKey: key(for: path)) as? Date else { return false }
        return Date().timeIntervalSince(stamp) < ttl
    }

    /// 「無い」を記録する（通信不可でも同じ扱い＝TTL 内は再試行しない）。
    static func markAbsent(path: String, defaults: UserDefaults = .standard) {
        defaults.set(Date(), forKey: key(for: path))
    }

    /// 見つかったので記録を消す。
    static func markPresent(path: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: path))
    }

    /// 不在記録をすべて消す（**バックアップがメタデータを書いた直後**に呼ぶ）。
    /// これが無いと、初回バックアップ後も最大 TTL のあいだ「バックアップ済み」バッジが出ない。
    public static func invalidateAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
