import Foundation

/// 共有セット 1 つ分の反映計画（純ロジック・テスト対象）。
/// 「何をコピー / 採用 / 掃除すべきか・何がバックアップ待ちか」を、アイテム記録＋
/// バックアップ記録＋共有フォルダの実在一覧から**決定的に**算出する。実行（API 呼び出し）は
/// `ShareSyncEngine` が担う。
///
/// ## 重複防止の原則（diagnostics-52 の実障害）
/// copy_batch の完了待ちがタイムアウトしても**ジョブはサーバー側で走り続ける**。
/// 以前は「失敗→autorename つきで再コピー」だったため、タイムアウト×リトライで
/// `IMG (1).jpg` 形式の重複が約 1,300 件量産された。対策:
/// 1. **宛先名は計画側で決定**（autorename 不使用）。同名衝突は決定的な連番で回避。
/// 2. **宛先が既に実在するなら「採用」**（コピーせず記録だけ更新）＝リトライが冪等になる。
/// 3. 過去の暴走で生まれた autorename 形式の重複は**掃除対象**として列挙する。
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

    /// 共有フォルダの実在ファイル（`list_folder` の結果）。
    public struct RemoteFile: Sendable, Equatable {
        public let pathLower: String
        public let contentHash: String?
        public init(pathLower: String, contentHash: String?) {
            self.pathLower = pathLower
            self.contentHash = contentHash
        }
    }

    public struct Plan: Sendable, Equatable {
        /// コピーすべき (refKey, コピー元, コピー先)。宛先は衝突しない名前を割り当て済み。
        public var copies: [Copy] = []
        /// コピー不要で記録だけ更新するもの（宛先が既に実在＝タイムアウト後に完了していた等）。
        public var adoptions: [Adoption] = []
        /// バックアップ完了待ちの refKey（ローカル写真でバックアップ記録なし）。
        public var waitingBackup: [String] = []
        /// 掃除すべき重複ファイル（過去の autorename 暴走で生まれた "name (N).ext"）。
        public var duplicatesToDelete: [String] = []

        public struct Copy: Sendable, Equatable {
            public let refKey: String
            public let fromPath: String
            public let toPath: String
            public init(refKey: String, fromPath: String, toPath: String) {
                self.refKey = refKey
                self.fromPath = fromPath
                self.toPath = toPath
            }
        }

        public struct Adoption: Sendable, Equatable {
            public let refKey: String
            public let sharedPathLower: String
            public let contentHash: String?
            public init(refKey: String, sharedPathLower: String, contentHash: String?) {
                self.refKey = refKey
                self.sharedPathLower = sharedPathLower
                self.contentHash = contentHash
            }
        }
    }

    /// - Parameters:
    ///   - items: セットのアイテム記録。
    ///   - backupByLocalID: localIdentifier → バックアップ記録（"L-" 写真の実体解決）。
    ///   - shareRoot: 共有ルート（宛先パスの組み立て用）。
    ///   - folderName: セットフォルダ名。
    ///   - remoteFiles: セットフォルダの実在ファイル。nil は「未照合」＝存在チェック・採用・
    ///     掃除を行わない（コピーの宛先割り当てのみ）。
    public static func plan(items: [ShareItemLite],
                            backupByLocalID: [String: BackupRef],
                            shareRoot: String,
                            folderName: String,
                            remoteFiles: [RemoteFile]? = nil) -> Plan {
        var plan = Plan()
        let remoteByPath: [String: RemoteFile]? = remoteFiles.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.pathLower, $0) })
        }
        /// この計画内で使用済みの宛先（小文字）。同名ソースの衝突回避に使う。
        var usedDestinations = Set<String>()
        /// 記録済み sharedPath は最初から予約しておく（新規の宛先が既存コピーと衝突しないように）。
        for item in items {
            if let shared = item.sharedPath { usedDestinations.insert(shared.lowercased()) }
        }

        /// 衝突しない宛先を決定的に割り当てる（"a.jpg" → "a 2.jpg" → "a 3.jpg" …）。
        /// 実在一覧との衝突は**採用候補**なのでここでは避けない（下で採用判定する）。
        func assignDestination(fromPath: String) -> String {
            let filename = (fromPath as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension
            let stem = (filename as NSString).deletingPathExtension
            var candidate = filename
            var n = 2
            while usedDestinations.contains("\(shareRoot)/\(folderName)/\(candidate)".lowercased()) {
                candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            let dest = "\(shareRoot)/\(folderName)/\(candidate)"
            usedDestinations.insert(dest.lowercased())
            return dest
        }

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
                plan.waitingBackup.append(item.refKey)
                continue
            }

            func copyOrAdopt() {
                let dest = assignDestination(fromPath: source.dropboxPath)
                // 宛先が既に実在するなら採用する（タイムアウト後に完了していたジョブの成果や
                // 前回の残置）。ソースのハッシュが分かっていて一致しない場合だけコピーへ回す
                // （同名別写真の可能性）——その場合も autorename に頼らず別名を割り当てる。
                if let remote = remoteByPath?[dest.lowercased()] {
                    if source.contentHash == nil || source.contentHash == remote.contentHash {
                        plan.adoptions.append(.init(refKey: item.refKey,
                                                    sharedPathLower: remote.pathLower,
                                                    contentHash: remote.contentHash))
                        return
                    }
                    // 中身が違う → 別名でコピー。
                    let alt = assignDestination(fromPath: source.dropboxPath)
                    plan.copies.append(.init(refKey: item.refKey,
                                             fromPath: source.dropboxPath, toPath: alt))
                    return
                }
                plan.copies.append(.init(refKey: item.refKey,
                                         fromPath: source.dropboxPath, toPath: dest))
            }

            switch item.state {
            case .pending, .failed, .waitingBackup:
                copyOrAdopt()
            case .copied:
                // 共有側から消えた（外部削除）→ 再コピーで自己修復。
                if let remoteByPath, let shared = item.sharedPath,
                   remoteByPath[shared.lowercased()] == nil {
                    copyOrAdopt()
                    continue
                }
                // 元が更新された（バックアップの content_hash が変わった）→ 再コピー。
                if let sourceHash = source.contentHash, let sharedHash = item.sharedContentHash,
                   sourceHash != sharedHash {
                    copyOrAdopt()
                }
            }
        }

        // 掃除: 過去の autorename 暴走で生まれた "name (N).ext" を消す。条件は 3 つとも必要:
        // (1) どのアイテムにも記録されていない、(2) 元名のファイルが実在する、
        // (3) **元名のファイルと中身（content_hash）が一致する**。
        //
        // ⚠️ (3) が要る理由: 元のファイル名自体が "IMG (1).jpg" の**別写真**は珍しくない
        // （ダウンロード由来など）。名前の形だけで消すと、たまたま "IMG.jpg" が同居している
        // だけでユーザーの写真が削除され、しかも次回の反映で再コピー → また削除の
        // 空回りループになる（レビューでテストにより再現）。中身が同じものだけを消す。
        if let remoteFiles {
            let owned = Set(items.compactMap { $0.sharedPath?.lowercased() })
            let byPath = Dictionary(remoteFiles.map { ($0.pathLower, $0) },
                                    uniquingKeysWith: { first, _ in first })
            for file in remoteFiles {
                guard !owned.contains(file.pathLower),
                      let basePath = autorenameBase(of: file.pathLower),
                      let baseFile = byPath[basePath],
                      // ハッシュ不明（片方でも nil）なら消さない＝安全側に倒す。
                      let hash = file.contentHash, let baseHash = baseFile.contentHash,
                      hash == baseHash
                else { continue }
                plan.duplicatesToDelete.append(file.pathLower)
            }
            plan.duplicatesToDelete.sort()
        }
        return plan
    }

    /// セットフォルダの絶対パスを組み立てる。**不正なフォルダ名は nil**（呼び出し側は中断する）。
    ///
    /// ⚠️ 削除系（セット削除は `<root>/<folderName>` をフォルダごと消す）で使うため、
    /// 空文字・パス区切り・親参照を含む名前は必ず弾く。空名を許すと
    /// `"\(root)/" ` になり **共有ルート全体を削除**してしまう（レビュー指摘）。
    public static func setFolderPath(shareRoot: String, folderName: String) -> String? {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              name != ".", name != ".." else { return nil }
        let root = shareRoot.hasSuffix("/") ? String(shareRoot.dropLast()) : shareRoot
        guard !root.isEmpty, root != "/" else { return nil }
        return "\(root)/\(name)"
    }

    /// "…/name (3).jpg" → "…/name.jpg"（autorename 形式でなければ nil）。
    static func autorenameBase(of pathLower: String) -> String? {
        let filename = (pathLower as NSString).lastPathComponent
        let directory = (pathLower as NSString).deletingLastPathComponent
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard let open = stem.lastIndex(of: "("), stem.hasSuffix(")"),
              open > stem.startIndex else { return nil }
        let digits = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let baseStem = String(stem[..<open]).trimmingCharacters(in: .whitespaces)
        guard !baseStem.isEmpty else { return nil }
        let baseName = ext.isEmpty ? baseStem : "\(baseStem).\(ext)"
        return directory.isEmpty ? baseName : "\(directory)/\(baseName)"
    }
}
