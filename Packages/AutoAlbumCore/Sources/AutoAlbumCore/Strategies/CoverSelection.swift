import Foundation

/// アルバムのカバー写真を賢く選ぶ共通ロジック（旅行・フォルダアルバム共用・純）。
/// お気に入り＞横長＞座標あり＞中心時刻に近い、でスコアし最良の1枚の id を返す。
func pickCoverRef(_ members: [EnrichedPhoto]) -> String? {
    guard !members.isEmpty else { return nil }
    let sortedDates = members.compactMap(\.captureDate).sorted()
    let median = sortedDates.isEmpty ? nil : sortedDates[sortedDates.count / 2]
    func score(_ p: EnrichedPhoto) -> Double {
        var s = 0.0
        if p.isFavorite { s += 100 }
        if let a = p.aspect, a > 1.1 { s += 10 }   // 横長
        if p.hasCoordinate { s += 5 }
        if let pd = p.captureDate, let median { s -= abs(pd.timeIntervalSince(median)) / 86_400 }
        return s
    }
    return members.max { score($0) < score($1) }?.id
}

/// 値を出現頻度の多い順に重複なしで返す共通ヘルパー（地名・人物の集計用）。
func rankedByFrequency(_ values: [String]) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for v in values where !v.isEmpty {
        if counts[v] == nil { order.append(v) }
        counts[v, default: 0] += 1
    }
    return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
}
