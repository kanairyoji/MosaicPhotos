import Foundation

/// 共有セット 1 つ分の反映計画（純ロジック・テスト対象）。
/// 「何をコピーすべきか / 何がバックアップ待ちか」を、アイテム記録＋バックアップ記録＋
/// （あれば）共有フォルダの実在一覧から決定的に算出する。実行（API 呼び出し）は
/// `ShareSyncEngine` が担う。
public enum SharePlanning {

    /// バックアップ記録の参照値（localIdentifier で引く）。
    public struct BackupRef: Sendable, Equatable {
        public let dropboxPath: String
        public let contentHash: String?
        public init(dropboxPath: String, contentHash: String?) {
            self.dropboxPath = dropboxPath
            self.contentHash = contentHash
        }
    }

    public struct Plan: Sendable, Equatable {
        /// コピーすべき (refKey, コピー元パス)。新規・失敗再試行・ドリフト・共有側消失の再コピーを含む。
        public var copies: [Copy]
        /// バックアップ完了待ちの refKey（ローカル写真でバックアップ記録なし）。
        public var waitingBackup: [String]

        public struct Copy: Sendable, Equatable {
            public let refKey: String
            public let fromPath: String
            public init(refKey: String, fromPath: String) {
                self.refKey = refKey
                self.fromPath = fromPath
            }
        }
    }

    /// - Parameters:
    ///   - items: セットのアイテム記録。
    ///   - backupByLocalID: localIdentifier → バックアップ記録（"L-" 写真の実体解決）。
    ///   - remotePresentLower: 共有セットフォルダの実在ファイル（path_lower）。nil は「未照合」
    ///     （存在チェックを行わない）。空 Set は「照合したが何も無い」＝コピー済みも再コピー対象。
    public static func plan(items: [ShareItemLite],
                            backupByLocalID: [String: BackupRef],
                            remotePresentLower: Set<String>? = nil) -> Plan {
        var copies: [Plan.Copy] = []
        var waiting: [String] = []

        for item in items {
            let source: BackupRef?
            if item.refKey.hasPrefix("C-") {
                // クラウド写真: 原本パスから直接コピー（バックアップ不要）。
                source = BackupRef(dropboxPath: String(item.refKey.dropFirst(2)), contentHash: nil)
            } else if item.refKey.hasPrefix("L-") {
                source = backupByLocalID[String(item.refKey.dropFirst(2))]
            } else {
                source = nil
            }
            guard let source else {
                waiting.append(item.refKey)
                continue
            }

            switch item.state {
            case .pending, .failed, .waitingBackup:
                copies.append(.init(refKey: item.refKey, fromPath: source.dropboxPath))
            case .copied:
                // 共有側から消えた（外部削除）→ 再コピーで自己修復。
                if let present = remotePresentLower,
                   let shared = item.sharedPath, !present.contains(shared.lowercased()) {
                    copies.append(.init(refKey: item.refKey, fromPath: source.dropboxPath))
                    continue
                }
                // 元が更新された（バックアップの content_hash が変わった）→ 再コピー。
                if let sourceHash = source.contentHash, let sharedHash = item.sharedContentHash,
                   sourceHash != sharedHash {
                    copies.append(.init(refKey: item.refKey, fromPath: source.dropboxPath))
                }
            }
        }
        return Plan(copies: copies, waitingBackup: waiting)
    }

    /// コピー先パスを組み立てる（`<共有ルート>/<フォルダ名>/<元ファイル名>`）。
    /// 衝突は Dropbox 側の autorename に任せ、結果の実パスを記録する。
    public static func destinationPath(shareRoot: String, folderName: String,
                                       fromPath: String) -> String {
        let filename = (fromPath as NSString).lastPathComponent
        return "\(shareRoot)/\(folderName)/\(filename)"
    }
}
