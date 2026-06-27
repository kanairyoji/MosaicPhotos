import Foundation

/// Dropbox のパス（フォルダ名）からアルバム名を推測してグルーピングする戦略。
/// 正規表現ルールでパス → 名前を抽出し、同名の写真を1アルバムにまとめる。
/// クラウド（cloudPath を持つ）写真のみ対象で、GPS が無くてもフォルダ名だけで成立する。
/// 戦略 ID は `"pathAlbum"`。時間＋場所アルバムとは別セクションに表示する。
public struct PathAlbumStrategy: Sendable {
    public static let strategyID = "pathAlbum"

    public let rules: [PathAlbumRule]
    /// アルバムとして採用する最小枚数（ノイズ抑制）。
    public let minPhotos: Int

    public init(rules: [PathAlbumRule], minPhotos: Int = 2) {
        self.rules = rules
        self.minPhotos = minPhotos
    }

    /// グルーピングの 1 まとまり（名前＋年）。
    private struct Group {
        let name: String
        let year: Int?
        var members: [EnrichedPhoto] = []
        var folderStarts: [Date] = []
        var folderEnds: [Date] = []
    }

    /// クラウド写真からフォルダ名アルバムの下書きを作る。新しい（endDate が大きい）順。
    /// フォルダ名から日付（`FolderDateParser`）も取り出し、**名前＋年でグループ**する
    /// （年違いは別アルバム）。日付があればアルバムの期間に採用し、無ければメンバーの撮影日から算出。
    /// 名前から日付は除去せず、表示は「名前 (年)」（名前に年が含まれていれば付けない）。
    public func makeAlbums(fromCloud photos: [EnrichedPhoto],
                           calendar: Calendar = .current, locale: Locale = .current,
                           now: Date = Date()) -> [GeneratedAlbumDraft] {
        guard !rules.isEmpty else { return [] }

        var groups: [String: Group] = [:]
        var order: [String] = []
        var dateByDir: [String: FolderDate?] = [:]   // フォルダ単位でメモ化（写真ごとに再解析しない）
        for photo in photos {
            guard let path = photo.ref?.cloudPath,
                  let name = PathAlbumNamer.name(forPath: path, rules: rules) else { continue }
            // 日付はフォルダ部（ファイル名を除く）から抽出（ファイル名中の日付に引っ張られないため）。
            let dir = (path as NSString).deletingLastPathComponent
            let folderDate: FolderDate?
            if let cached = dateByDir[dir] {
                folderDate = cached
            } else {
                folderDate = FolderDateParser.parse(dir, calendar: calendar, locale: locale, now: now)
                dateByDir[dir] = folderDate
            }
            let year = folderDate.map { calendar.component(.year, from: $0.start) }
            let key = "\(name)|\(year.map(String.init) ?? "")"
            if groups[key] == nil { groups[key] = Group(name: name, year: year); order.append(key) }
            groups[key]!.members.append(photo)
            if let folderDate {
                groups[key]!.folderStarts.append(folderDate.start)
                groups[key]!.folderEnds.append(folderDate.end)
            }
        }

        var drafts: [GeneratedAlbumDraft] = []
        for key in order {
            guard let g = groups[key], g.members.count >= minPhotos else { continue }
            // 期間：フォルダ日付があればそれ（複数フォルダなら union）、無ければ撮影日から。
            let exif = g.members.compactMap(\.captureDate)
            let start = g.folderStarts.min() ?? exif.min() ?? .distantPast
            let end = g.folderEnds.max() ?? exif.max() ?? .distantPast
            let located = g.members.filter(\.hasCoordinate)
            let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
            let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
            // 表示名「名前 (年)」。名前に既に年が含まれる場合は冗長なので付けない（日付除去はしない）。
            let title: String
            if let y = g.year, !g.name.contains(String(y)) { title = "\(g.name) (\(y))" } else { title = g.name }
            drafts.append(GeneratedAlbumDraft(
                strategyID: Self.strategyID, placeName: title, places: [g.name], country: nil,
                startDate: start, endDate: end, memberRefs: g.members.map(\.id),
                coverRef: pickCoverRef(g.members), people: rankedByFrequency(g.members.flatMap(\.people)),
                latitude: lat, longitude: lon))
        }
        return drafts.sorted { $0.endDate > $1.endDate }
    }
}
