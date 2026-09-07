import Foundation

/// 台帳ストアの**開く前の控え**（ADR-186）。
///
/// ## なぜ要るか
/// モデル更新に伴うスキーマ変更（optional 列の追加）は軽量マイグレーションで既存データを保つが、
/// 万一マイグレーションに失敗すると `makeResilientModelContainer` は台帳を退避／削除して作り直す
/// ＝**ユーザーの学習結果（人物名・修正）が失われる**。そこで、アプリの版が変わって最初に開く前に
/// ストアファイル（.store / -wal / -shm）の控えを取り、失敗したら控えから戻して 1 回だけ再試行する。
///
/// ## 約束
/// - 控えは**アプリの版（build）ごとに 1 世代**。同じ版で何度も取り直さない（起動を重くしない）。
/// - 復元は `.ledger` 方針の台帳だけ。再構築できるキャッシュは控えない。
/// - 控えはユーザー領域（Application Support/StoreSnapshots）に置き、バックアップ対象から外す。
public enum StoreSnapshot {

    static let suffixes = ["", "-wal", "-shm"]

    /// 控えの置き場。
    public static func directory(for name: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("StoreSnapshots", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// 現在のアプリの版の印（build 番号＋バージョン）。
    public static var currentBuildMarker: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }

    private static func markerKey(_ name: String) -> String { "storeSnapshot.build.\(name)" }

    /// アプリの版が変わって最初の起動なら、開く前に控えを取る（同じ版では何もしない）。
    /// - Returns: 控えを取ったか。
    @discardableResult
    public static func takeIfBuildChanged(name: String, storeURL: URL,
                                          defaults: UserDefaults = .standard,
                                          marker: String = currentBuildMarker) -> Bool {
        guard defaults.string(forKey: markerKey(name)) != marker else { return false }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            defaults.set(marker, forKey: markerKey(name))   // 台帳がまだ無い＝控えるものが無い
            return false
        }
        let ok = copy(storeURL: storeURL, to: directory(for: name))
        if ok {
            defaults.set(marker, forKey: markerKey(name))
            Diagnostics.mark("store: '\(name)' snapshot taken before first open on \(marker)")
        }
        return ok
    }

    /// 控えから戻す（開けなかったときの 1 回だけの再試行用）。
    /// - Returns: 戻せたか（控えが無ければ false）。
    public static func restore(name: String, storeURL: URL) -> Bool {
        let dir = directory(for: name)
        let base = storeURL.lastPathComponent
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(base).path) else { return false }
        let fm = FileManager.default
        for suffix in suffixes {
            let dst = URL(fileURLWithPath: storeURL.path + suffix)
            let src = dir.appendingPathComponent(base + suffix)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) {
                do { try fm.copyItem(at: src, to: dst) } catch { return false }
            }
        }
        Diagnostics.mark("store: '\(name)' restored from snapshot")
        return true
    }

    private static func copy(storeURL: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutableDir = dir; try? mutableDir.setResourceValues(values)
            let base = storeURL.lastPathComponent
            for suffix in suffixes {
                let src = URL(fileURLWithPath: storeURL.path + suffix)
                let dst = dir.appendingPathComponent(base + suffix)
                try? fm.removeItem(at: dst)
                if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
            }
            return true
        } catch {
            Diagnostics.mark("store: snapshot failed — \(error.localizedDescription)")
            return false
        }
    }
}
