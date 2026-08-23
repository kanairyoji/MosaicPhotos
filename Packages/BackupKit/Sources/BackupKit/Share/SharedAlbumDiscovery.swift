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
                         name: (group.display as NSString).lastPathComponent,
                         photoCount: sorted.count,
                         coverPath: sorted.first,
                         providerName: provider)
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                || ($0.name == $1.name && ($0.providerName ?? "") < ($1.providerName ?? ""))
        }
    }
}
