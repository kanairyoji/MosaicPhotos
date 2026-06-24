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

    /// クラウド写真からフォルダ名アルバムの下書きを作る。新しい（endDate が大きい）順。
    public func makeAlbums(fromCloud photos: [EnrichedPhoto]) -> [GeneratedAlbumDraft] {
        guard !rules.isEmpty else { return [] }

        var byName: [String: [EnrichedPhoto]] = [:]
        var order: [String] = []
        for photo in photos {
            guard let path = photo.ref?.cloudPath,
                  let name = PathAlbumNamer.name(forPath: path, rules: rules) else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(photo)
        }

        var drafts: [GeneratedAlbumDraft] = []
        for name in order {
            guard let members = byName[name], members.count >= minPhotos else { continue }
            let dates = members.compactMap(\.captureDate)
            let start = dates.min() ?? .distantPast
            let end = dates.max() ?? .distantPast
            let located = members.filter(\.hasCoordinate)
            let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
            let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
            drafts.append(GeneratedAlbumDraft(
                strategyID: Self.strategyID, placeName: name, places: [name], country: nil,
                startDate: start, endDate: end, memberRefs: members.map(\.id),
                coverRef: pickCoverRef(members), people: rankedByFrequency(members.flatMap(\.people)),
                latitude: lat, longitude: lon))
        }
        return drafts.sorted { $0.endDate > $1.endDate }
    }
}
