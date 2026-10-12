import Foundation

/// **同じ Dropbox の他の端末の共有コピー**のうち、同じ中身が別の場所にもあるもの（ADR-276・純ロジック）。
///
/// ## なぜ要るか
/// 同じ Dropbox を 2 台で使うと、相手が共有した写真は**相手の Backup のコピー**と
/// **相手の Share のコピー**の 2 か所にあり、こちらの端末では 2 枚に見え、2 回解析されていた。
/// 自分の共有コピーは共有ルートごと表示と解析から外している（`ShareVisibility` /
/// `AnalysisCandidates.excludedCloudPathPrefixes`）が、それは**自分の**ものしか知らない。
///
/// ## 規則
/// - 対象は `<root>/<他の端末>/Share/…` のファイルだけ（自分の端末・家族フォルダは見ない）。
/// - 同じ `content_hash` が **Share の外**にもあれば、その共有コピーは重複（残す方を返す）。
/// - Share の外に無ければ**隠さない**（写真が消えるより重複する方がまだ良い・`BackupCopyHiding` と同じ）。
/// - 残す方は決定的に選ぶ（パスの小さい方）。毎回違うと表示の指紋が揺れて再構築が止まらない。
public enum ShareCopyDuplicates {

    /// - Parameters:
    ///   - hashesByPath: 同期しているクラウド写真（パス → content_hash）。パスの大小は問わない。
    ///   - backupRoot: バックアップのルート（`/MosaicPhotos`）。
    ///   - ownDeviceFolder / ownDeviceID: 自分の端末（`BackupLayout.isOwnDeviceFolder` で外す）。
    /// - Returns: 隠す共有コピー（パス小文字）→ 代わりに残すコピー（パス小文字）。
    public static func otherDevicesShareCopies(hashesByPath: [String: String], backupRoot: String,
                                               ownDeviceFolder: String,
                                               ownDeviceID: String) -> [String: String] {
        let root = (backupRoot.hasSuffix("/") ? String(backupRoot.dropLast()) : backupRoot).lowercased()
        let share = BackupLayout.shareSubfolder.lowercased()

        /// `<root>/<端末>/Share/…` なら端末フォルダ名を返す。
        func shareDevice(_ lower: String) -> String? {
            guard lower.hasPrefix(root + "/") else { return nil }
            let parts = lower.dropFirst(root.count + 1).split(separator: "/", maxSplits: 2)
            guard parts.count == 3, parts[1] == share else { return nil }
            return String(parts[0])
        }

        var keptByHash: [String: String] = [:]          // hash → Share の外の最小のパス
        var otherShares: [(path: String, hash: String)] = []
        for (path, hash) in hashesByPath {
            let lower = path.lowercased()
            let hashLower = hash.lowercased()
            if let device = shareDevice(lower) {
                if !BackupLayout.isOwnDeviceFolder(device, ownDeviceFolder: ownDeviceFolder,
                                                   ownDeviceID: ownDeviceID) {
                    otherShares.append((lower, hashLower))
                }
                continue   // どの端末の Share も「残す方」にはしない
            }
            if let current = keptByHash[hashLower], current <= lower { continue }
            keptByHash[hashLower] = lower
        }
        var out: [String: String] = [:]
        for copy in otherShares {
            if let kept = keptByHash[copy.hash] { out[copy.path] = kept }
        }
        return out
    }
}
