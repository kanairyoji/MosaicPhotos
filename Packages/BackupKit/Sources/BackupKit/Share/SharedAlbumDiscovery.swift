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

        public var id: String { folderPath.lowercased() }

        public init(folderPath: String, name: String, photoCount: Int, coverPath: String?) {
            self.folderPath = folderPath
            self.name = name
            self.photoCount = photoCount
            self.coverPath = coverPath
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

        // folderPathLower → (表示パス, メンバーパス一覧)
        var groups: [String: (display: String, paths: [String])] = [:]
        for path in itemPaths {
            let lower = path.lowercased()
            guard let rootIndex = rootsLower.firstIndex(where: {
                lower.hasPrefix($0 + "/")
            }) else { continue }
            let root = rootsLower[rootIndex]
            let relative = lower.dropFirst(root.count + 1)
            let folderDisplay: String
            let folderLower: String
            if let slash = relative.firstIndex(of: "/") {
                // ルート直下のサブフォルダ＝共有セット。
                let subLength = relative.distance(from: relative.startIndex, to: slash)
                let prefixLength = root.count + 1 + subLength
                folderDisplay = String(path.prefix(prefixLength))
                folderLower = String(lower.prefix(prefixLength))
            } else {
                // ルート直下の写真＝フォルダ自身がセット。
                folderLower = root
                folderDisplay = String(path.prefix(root.count))
            }
            groups[folderLower, default: (folderDisplay, [])].paths.append(path)
        }

        return groups.values.map { group in
            let sorted = group.paths.sorted()
            return Album(folderPath: group.display,
                         name: (group.display as NSString).lastPathComponent,
                         photoCount: sorted.count,
                         coverPath: sorted.first)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
