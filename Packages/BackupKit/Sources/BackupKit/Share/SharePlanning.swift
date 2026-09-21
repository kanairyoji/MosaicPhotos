import Foundation

/// 共有セット 1 つ分の反映計画（純ロジック・テスト対象・ADR-209）。
///
/// ## 考え方: 「望ましい集合」と「実在」の差分
///
/// ```
/// 望ましい = { 宛先名(メンバー) : 元が解決できるメンバー }      ← 記録を見ずに決まる
/// 実在     = セットフォルダ直下の写真                          ← 一覧から分かる
///
/// コピー = 望ましい − 実在
/// 削除   = 実在 − 望ましい
/// ```
///
/// 宛先名は `ShareNaming.sharedFileName` が**中身から決める**ので、
/// 同じ写真は必ず同じ名前になる。だから「どこへコピーしたか」を覚えておく必要がない。
///
/// ## これで消えた仕組み（以前は全部ここにあった）
/// - 4 状態の状態機械（`pending` / `waitingBackup` / `copied` / `failed`）と
///   `sharedPath` / `sharedContentHash` の記録
/// - **採用**（宛先が既に在るなら記録だけ更新）——「在る」＝終わっている、で足りる
/// - **宛先名の予約表と別名割当**——別の写真は別の名前になるので衝突しない
/// - **ドリフト検知**（元が更新されたら再コピー）——hash が変われば名前が変わる
/// - **`autorename` 残骸の掃除**（"name (N).ext"・中身一致の安全条件つき）——衝突しないので生まれない
/// - **墓標**（遅れて完走したジョブが作るファイルを覚えておく）——望ましくない名前は次の差分で消える
///
/// ⚠️ 代償は「**共有フォルダのファイル名が元の名前と違う**」こと
/// （`IMG_1234.jpg` → `IMG_1234--3f9a2c1d.jpg`）。受信側アプリの表示には出ないが、
/// 家族が Dropbox アプリや Finder で直接見ると印が見える。
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

    /// 解決済みのコピー元と、そこから決まる宛先（解析データの組み立てにも使う）。
    public struct SourceRef: Sendable, Equatable {
        /// コピー元の Dropbox パス。
        public let fromPath: String
        /// その写真の `content_hash`（分かる場合。解析データのキーになる）。
        public let contentHash: String?
        /// 共有フォルダでの宛先（小文字）。
        public let destinationLower: String
        public init(fromPath: String, contentHash: String?, destinationLower: String) {
            self.fromPath = fromPath
            self.contentHash = contentHash
            self.destinationLower = destinationLower
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
        /// コピーすべき (refKey, コピー元, コピー先)。宛先は中身から決まっている。
        public var copies: [Copy] = []
        /// 消すべきファイル（セットフォルダ直下で、望ましい集合に無いもの）。
        public var deletions: [String] = []
        /// バックアップ完了待ちの refKey（ローカル写真でバックアップ記録なし）。
        public var waitingBackup: [String] = []
        /// 既に望ましい状態で置かれている件数（画面の「共有済み N/M」に使う）。
        public var present: Int = 0
        /// ⚠️ 削除を見送ったか（望ましい集合が空なのにメンバーが居る＝解決に失敗している回）。
        /// 記録に残して、黙って何もしない状態が続かないようにする。
        public var skippedDeletionsForSafety: Bool = false
        /// refKey → 解決したコピー元と宛先。解析データ（キーは写真の content_hash）を
        /// 組むときに、**いま共有フォルダに在る写真だけ**を選ぶために使う。
        public var sourceByRefKey: [String: SourceRef] = [:]

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
    }

    /// - Parameters:
    ///   - items: セットのメンバー（refKey だけ・状態は持たない）。
    ///   - backupByLocalID: localIdentifier → バックアップ記録（"L-" 写真の実体解決）。
    ///   - cloudHashByPath: クラウド原本（"C-"）のパス小文字 → content_hash（分かるものだけ）。
    ///   - setFolder: セットフォルダの絶対パス。
    ///   - remoteFiles: セットフォルダ直下の実在ファイル。**nil は「一覧が取れなかった」**
    ///     ＝削除もコピーもしない（実在不明のまま動くと壊す）。
    public static func plan(items: [ShareItemLite],
                            backupByLocalID: [String: BackupRef],
                            cloudHashByPath: [String: String] = [:],
                            setFolder: String,
                            remoteFiles: [RemoteFile]?) -> Plan {
        var plan = Plan()

        // 1. 望ましい集合を作る（宛先パス小文字 → コピー元）。
        //
        // ⚠️ **refKey 順に決める**。印が衝突したときに「どちらが短い名前を取るか」が
        // メンバーの追加順で変わると、外して入れ直しただけで名前が入れ替わり、
        // 削除とコピーが無駄に走る。順序に依存しない規則にする。
        var desired: [String: (refKey: String, fromPath: String, toPath: String)] = [:]
        var waiting: [String] = []
        for item in items.sorted(by: { $0.refKey < $1.refKey }) {
            guard let source = resolveSource(refKey: item.refKey,
                                             backupByLocalID: backupByLocalID,
                                             cloudHashByPath: cloudHashByPath) else {
                waiting.append(item.refKey)
                continue
            }
            // 同じ写真が同じセットに 2 回入っていても宛先は 1 つ（重複しない）。
            if plan.sourceByRefKey[item.refKey] != nil { continue }

            // ⚠️ 宛先は**中身から一意に決まる**（印は SHA-256 の全桁）。だから
            // 衝突を解く仕組みが要らない——桁を切り詰めていた頃は、衝突したときに
            // 辞書の代入で片方が黙って落ちた（家族に届かない写真が生まれた）。
            let identity = ShareNaming.identity(refKey: item.refKey, contentHash: source.contentHash)
            let filename = ShareNaming.sharedFileName(
                sourceFileName: (source.dropboxPath as NSString).lastPathComponent,
                identity: identity)
            let toPath = "\(setFolder)/\(filename)"
            desired[toPath.lowercased()] = (item.refKey, source.dropboxPath, toPath)
            plan.sourceByRefKey[item.refKey] = SourceRef(fromPath: source.dropboxPath,
                                                         contentHash: source.contentHash,
                                                         destinationLower: toPath.lowercased())
        }
        plan.waitingBackup = waiting.sorted()

        // 一覧が取れなかった回は何も決めない（実在が分からないまま消す/コピーするのが最悪）。
        guard let remoteFiles else { return plan }

        let presentPaths = Set(remoteFiles.map(\.pathLower))

        // 2. コピー ＝ 望ましい − 実在。
        for (lower, entry) in desired where !presentPaths.contains(lower) {
            plan.copies.append(.init(refKey: entry.refKey, fromPath: entry.fromPath,
                                     toPath: entry.toPath))
        }
        plan.copies.sort { $0.toPath < $1.toPath }
        plan.present = desired.count - plan.copies.count

        // 3. 削除 ＝ 実在 − 望ましい。
        //
        // ⚠️ **セットフォルダは「セットの射影」**なので、直下にあってよいファイルは
        //    望ましい集合のものだけ。それ以外は消す——名前の形では絞らない。
        //
        //    最初は「このアプリが置いた名前（`--<印>`）のものだけ消す」という安全弁にしていた。
        //    家族が手で置いたファイルを守るためだが、**旧方式のコピー（元のファイル名）が
        //    永久に残る**ことになり、家族には同じ写真が 2 枚見えた。重複の害のほうが大きい。
        //    守るのは「フォルダ」と「解析データ」——直下のファイルだけを対象にするので、
        //    家族が作ったサブフォルダと `.mosaic-share/` は触らない。
        //
        // ⚠️ **安全弁**: 望ましい集合が空なのに**メンバーは居る**回は何も消さない。
        //    バックアップ記録の読み出しに失敗したような回に、共有フォルダを空にしないため
        //    （作り直すので失われはしないが、家族には「全部消えて戻る」が見える）。
        //    メンバーも 0 なら本当に空が正しいので、そのまま全部消す。
        if desired.isEmpty && !items.isEmpty {
            plan.skippedDeletionsForSafety = true
            return plan
        }
        for file in remoteFiles where !desired.keys.contains(file.pathLower) {
            plan.deletions.append(file.pathLower)
        }
        plan.deletions.sort()
        return plan
    }

    /// refKey → コピー元（解決できなければ nil＝バックアップ待ち）。
    private static func resolveSource(refKey: String,
                                      backupByLocalID: [String: BackupRef],
                                      cloudHashByPath: [String: String]) -> BackupRef? {
        if refKey.hasPrefix("C-") {
            // クラウド写真: 原本パスから直接コピー（バックアップ不要）。
            let path = String(refKey.dropFirst(2))
            return BackupRef(dropboxPath: path, contentHash: cloudHashByPath[path.lowercased()])
        }
        if refKey.hasPrefix("L-") {
            return backupByLocalID[String(refKey.dropFirst(2))]
        }
        return nil
    }

    /// セットフォルダの絶対パスを組み立てる。**不正なフォルダ名は nil**（呼び出し側は中断する）。
    ///
    /// レイアウトは `<root>/<端末フォルダ>/<セット名>`。**端末フォルダを挟むのが要点**で、
    /// 家族が同じ共有フォルダを使い、たまたま同じセット名（例「◯◯家」）を付けても
    /// **互いのファイルを上書きしない**（バックアップの ADR-41 と同じ考え方・同じ短 ID を使う）。
    ///
    /// ⚠️ 削除系（セット削除はこのパスをフォルダごと消す）で使うため、空文字・パス区切り・
    /// 親参照を含む名前は必ず弾く。空名を許すと `"\(root)/"` になり
    /// **共有ルート全体を削除**してしまう（レビュー指摘）。
    public static func setFolderPath(shareRoot: String, folderName: String,
                                     deviceFolder: String? = nil) -> String? {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeFolderComponent(name) else { return nil }
        var root = shareRoot.hasSuffix("/") ? String(shareRoot.dropLast()) : shareRoot
        guard !root.isEmpty, root != "/" else { return nil }
        if let deviceFolder {
            let device = deviceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeFolderComponent(device) else { return nil }
            root += "/\(device)"
        }
        return "\(root)/\(name)"
    }

    /// フォルダ名 1 要素として安全か（空・パス区切り・親参照を弾く）。
    static func isSafeFolderComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\")
            && name != "." && name != ".."
    }
}
