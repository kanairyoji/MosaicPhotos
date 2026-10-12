import Foundation

/// 受信側: 同期済みアイテムのパスから「クラウド共有で受け取ったアルバム」を発見する
/// （純ロジック・テスト対象）。共有セットは家族フォルダ直下のサブフォルダなので、
/// 家族フォルダ配下の写真を第一階層のフォルダ単位にグルーピングする。
/// フォルダを直接共有された（家族フォルダ自体がセットの）構成では、直下の写真を
/// フォルダ自身のアルバムとして扱う。
public enum SharedAlbumDiscovery {

    public struct Album: Sendable, Identifiable, Equatable {
        /// アルバムのフォルダパス（表示ケースのまま）。
        public let folderPath: String
        /// 表示名（フォルダ名）。
        public let name: String
        public let photoCount: Int
        /// カバー用の写真パス（決定的に選ぶ）。
        public let coverPath: String?
        /// 提供者（端末フォルダ名）。同じ共有フォルダを複数人で使うときの区別に使う。
        /// レイアウトが `<root>/<セット>` の場合は nil。
        public let providerName: String?

        public var id: String { folderPath.lowercased() }

        public init(folderPath: String, name: String, photoCount: Int, coverPath: String?,
                    providerName: String? = nil) {
            self.folderPath = folderPath
            self.name = name
            self.photoCount = photoCount
            self.coverPath = coverPath
            self.providerName = providerName
        }
    }

    /// - Parameters:
    ///   - itemPaths: 受信側の同期済み写真パス（表示ケース）。
    ///   - familyRoots: 家族フォルダ（`ShareSettingsKeys.currentFamilyFolders()`）。
    /// - Returns: 名前昇順のアルバム一覧。写真が 1 枚も無いフォルダは含まれない。
    public static func albums(itemPaths: [String], familyRoots: [String]) -> [Album] {
        let roots = familyRoots
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty && $0 != "/" }
        guard !roots.isEmpty else { return [] }
        let rootsLower = roots.map { $0.lowercased() }

        // ⚠️ セットは「**写真が直接入っているフォルダ**」とみなす（階層の深さに依存しない）。
        // 提供側は `<root>/<端末フォルダ>/<セット名>/` に置くが（家族が同名セットを作っても
        // 上書きしないための分離・ADR-41 と同じ）、`<root>/<セット名>/` の構成や
        // セットフォルダを直接共有された構成もあり得るため、階層数で決め打ちしない。
        // folderPathLower → (表示パス, メンバーパス一覧)
        var groups: [String: (display: String, paths: [String])] = [:]
        for path in itemPaths {
            let lower = path.lowercased()
            guard let rootIndex = rootsLower.firstIndex(where: {
                lower == $0 || lower.hasPrefix($0 + "/")
            }) else { continue }
            let root = rootsLower[rootIndex]
            let folderLower = (lower as NSString).deletingLastPathComponent
            guard !folderLower.isEmpty else { continue }
            // ⚠️ ADR-175: 共有はバックアップと同じルートの端末フォルダ配下 `Share/` に置く。
            // 家族が `/MosaicPhotos` ごと共有してきた場合、`Backup/` 配下の写真まで
            // 「共有アルバム」に見えてしまう。**`Share/` 配下だけ**を共有セットとして扱う
            // （旧配置 `/MosaicShare/...` は `Backup/` を含まないので従来どおり全部通る）。
            if SharedAlbumDiscovery.isUnderBackupSubfolder(folderLower, root: root) { continue }
            let folderDisplay = String(path.prefix(folderLower.count))
            groups[folderLower, default: (folderDisplay, [])].paths.append(path)
            _ = root
        }

        return groups.map { folderLower, group in
            let sorted = group.paths.sorted()
            // 提供者名: ルートとセットの間に階層があれば、その最初の要素を提供者とみなす。
            var provider: String?
            if let root = rootsLower.first(where: { folderLower.hasPrefix($0 + "/") }) {
                let relative = folderLower.dropFirst(root.count + 1)
                let components = relative.split(separator: "/")
                if components.count >= 2 {
                    // 表示パスから同じ位置を切り出して大小を保つ。
                    let prefixLength = root.count + 1 + components[0].count
                    provider = String(group.display.prefix(prefixLength))
                        .components(separatedBy: "/").last
                }
            }
            return Album(folderPath: group.display,
                         // ⚠️ 接頭辞（`People-` 等）は種類を見分けるための内部の印なので**表示しない**。
                         name: ShareNaming.displayName(
                             fromFolderName: (group.display as NSString).lastPathComponent),
                         photoCount: sorted.count,
                         coverPath: sorted.first,
                         providerName: provider)
        }
        // ⚠️ **全順序にする**（レビュー指摘）。以前は 1 つ目の比較が大文字小文字を無視し、
        // 2 つ目が完全一致のときだけ提供者で切っていたので、"Trip"/"trip" が「同順」なのに
        // "Trip" どうしには順序がある＝**比較不能が推移しない**。Swift の `sorted` は
        // 未定義動作で、同じデータでも並びが実行ごとに変わり得た（デバッグ版では落ちる）。
        .sorted {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:
                // 同じ綴り（大文字小文字違いを含む）は、提供者 → id で決定的に切る。
                if $0.providerName ?? "" != $1.providerName ?? "" {
                    return ($0.providerName ?? "") < ($1.providerName ?? "")
                }
                return $0.id < $1.id
            }
        }
    }

    /// **受け取ったアルバム**（ADR-276）: 家族フォルダに加えて、**同じ Dropbox の他の端末**の
    /// `Share`（`<root>/<端末>/Share`）も受け取ったものとして扱う。
    ///
    /// ⚠️ なぜ要るか: 同じ Dropbox を 2 台（2 人）で使うと、相手の共有セットは写真としては
    /// 見えるのに、家族フォルダに登録していないので**アルバムにならなかった**。
    /// 他の端末の `Share` は同期しているパス（`itemPaths`）から見つける（一覧を引き直さない）。
    /// 自分の端末は `BackupLayout.isOwnDeviceFolder` で外す（解析の発見と同じ規則）。
    /// 提供者名には端末フォルダ名を入れる（同じ名前のセットを 2 台が作っても見分けられる）。
    public static func receivedAlbums(itemPaths: [String], familyRoots: [String], backupRoot: String,
                                      ownDeviceFolder: String, ownDeviceID: String) -> [Album] {
        let root = backupRoot.lowercased().hasSuffix("/") ? String(backupRoot.dropLast()) : backupRoot
        let rootLower = root.lowercased()
        let share = BackupLayout.shareSubfolder.lowercased()
        var deviceRoots: [String: String] = [:]   // Share のパス（小文字）→ 端末フォルダ名（表示）
        for path in itemPaths {
            let lower = path.lowercased()
            guard lower.hasPrefix(rootLower + "/") else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 2)
            guard parts.count == 3, parts[1].lowercased() == share else { continue }
            let device = String(parts[0])
            guard !BackupLayout.isOwnDeviceFolder(device, ownDeviceFolder: ownDeviceFolder, ownDeviceID: ownDeviceID)
            else { continue }
            deviceRoots[rootLower + "/" + device.lowercased() + "/" + share] = device
        }
        // 家族フォルダとして登録済みのもの（`/MosaicPhotos` ごと等）と重ねない。
        let family = familyRoots.map { $0.lowercased() }
        let extra = deviceRoots.keys.filter { candidate in
            !family.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
        }.sorted()
        return albums(itemPaths: itemPaths, familyRoots: familyRoots + extra).map { album in
            guard album.providerName == nil,
                  let device = deviceRoots.first(where: { album.id.hasPrefix($0.key + "/") })?.value
            else { return album }
            return Album(folderPath: album.folderPath, name: album.name, photoCount: album.photoCount,
                         coverPath: album.coverPath, providerName: device)
        }
    }

    /// パスがバックアップ側（`…/<端末>/Backup/…`）にあるか（共有セットとして扱わない）。
    /// 端末フォルダの直下に `Backup` があり、その配下なら真。`Share` 配下・旧配置は偽。
    static func isUnderBackupSubfolder(_ folderLower: String, root: String) -> Bool {
        let relative = folderLower.dropFirst(root.count).split(separator: "/")
        // <端末>/Backup/... の形（端末フォルダの次の要素が Backup）。
        guard relative.count >= 2 else { return false }
        return relative[1].lowercased() == BackupLayout.backupSubfolder.lowercased()
    }
}
