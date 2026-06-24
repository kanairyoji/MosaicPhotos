import Foundation
import PhotoSourceKit

/// 時間＋場所から「旅行・お出かけ」アルバムを抽出する戦略。
///
/// 1. 座標の無い写真は前後の GPS から内挿補完（スクショ/編集写真も正しい旅行へ）。
/// 2. 常用地点（自宅・職場・行きつけ）を「同一セルで撮影した“異なる日数”が閾値以上」で検出（複数可）。
/// 3. 「自宅外の連続した撮影」を 1 旅行として束ねる（複数都市を跨いでも分割しない。時間ギャップで区切る）。
/// 4. スクリーンショットを除外し、最小枚数以上のまとまりを「場所（国）· 日付範囲」アルバム化。
///    カバーはお気に入り・横長・中心時刻を優先して賢く選定。代表座標・訪問地・人物も付与。
public struct TimePlaceStrategy: AlbumStrategy {
    public static let strategyID = "timePlace"
    public let id = TimePlaceStrategy.strategyID

    public init() {}

    public func makeAlbums(from photos: [EnrichedPhoto], params: AlbumGenParams) -> [GeneratedAlbumDraft] {
        let sorted = photos
            .filter { $0.captureDate != nil }
            .sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }   // 昇順
        guard !sorted.isEmpty else { return [] }

        let filled = backfillCoordinates(sorted)
        let frequent = frequentLocations(filled, params: params)
        let homeCountry = mostCommonCountry(filled)

        // 日単位で「自宅外（away）写真」と「在宅日」を仕分ける。
        // 旅行 = 連続する away 日のまとまり。多日旅行を日ごとに分割しない（cohesion）が、
        // 在宅日を挟んだり大きく日が空いたら別の旅行に分ける。
        var awayByDay: [Int: [EnrichedPhoto]] = [:]
        var homeDays: Set<Int> = []
        for photo in filled {
            let day = dayBucket(photo.captureDate!)
            if isAway(photo, frequent: frequent, params: params) {
                awayByDay[day, default: []].append(photo)
            } else if photo.hasCoordinate {
                homeDays.insert(day)   // 自宅付近で撮った日＝その日は在宅
            }
        }
        let awayDays = awayByDay.keys.sorted()
        guard !awayDays.isEmpty else { return [] }

        var trips: [[EnrichedPhoto]] = []
        var current: [EnrichedPhoto] = []
        var prevDay: Int?
        for day in awayDays {
            if let prev = prevDay {
                let homeBetween = (prev + 1..<day).contains { homeDays.contains($0) }
                if day - prev > params.maxTripGapDays || homeBetween {
                    trips.append(current)
                    current = []
                }
            }
            current.append(contentsOf: awayByDay[day] ?? [])
            prevDay = day
        }
        if !current.isEmpty { trips.append(current) }

        return trips
            .compactMap { makeDraft(from: $0, params: params, homeCountry: homeCountry) }
            .sorted { $0.endDate > $1.endDate }   // 新しい旅行を先頭に
    }

    // MARK: - GPS backfill

    /// 座標の無い写真に、時間的に最も近い GPS 付き写真の座標を補完する（O(n)・2 パス）。
    func backfillCoordinates(_ sorted: [EnrichedPhoto]) -> [EnrichedPhoto] {
        let n = sorted.count
        var prev = [Int?](repeating: nil, count: n)
        var last: Int?
        for i in 0..<n { if sorted[i].hasCoordinate { last = i }; prev[i] = last }
        var next = [Int?](repeating: nil, count: n)
        var following: Int?
        for i in stride(from: n - 1, through: 0, by: -1) { if sorted[i].hasCoordinate { following = i }; next[i] = following }

        return sorted.enumerated().map { (i, photo) in
            guard !photo.hasCoordinate, let pd = photo.captureDate else { return photo }
            var best: EnrichedPhoto?
            var bestDelta = Double.greatestFiniteMagnitude
            for idx in [prev[i], next[i]].compactMap({ $0 }) {
                guard let ld = sorted[idx].captureDate else { continue }
                let d = abs(pd.timeIntervalSince(ld))
                if d < bestDelta { bestDelta = d; best = sorted[idx] }
            }
            guard let best else { return photo }
            return photo.withCoordinate(latitude: best.latitude, longitude: best.longitude)
        }
    }

    // MARK: - Frequent locations

    func frequentLocations(_ photos: [EnrichedPhoto], params: AlbumGenParams) -> [(latitude: Double, longitude: Double)] {
        var daysByCell: [String: Set<Int>] = [:]
        var coordsByCell: [String: [(Double, Double)]] = [:]
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude, let date = photo.captureDate else { continue }
            let key = GeoGridKey.key(latitude: lat, longitude: lon, step: params.gridStepDegrees)
            daysByCell[key, default: []].insert(dayBucket(date))
            coordsByCell[key, default: []].append((lat, lon))
        }
        var centroids: [(latitude: Double, longitude: Double)] = []
        for (key, days) in daysByCell where days.count >= params.frequentMinDistinctDays {
            guard let coords = coordsByCell[key], !coords.isEmpty else { continue }
            let n = Double(coords.count)
            centroids.append((coords.map(\.0).reduce(0, +) / n, coords.map(\.1).reduce(0, +) / n))
        }
        return centroids
    }

    func isAway(_ photo: EnrichedPhoto, frequent: [(latitude: Double, longitude: Double)], params: AlbumGenParams) -> Bool {
        guard let lat = photo.latitude, let lon = photo.longitude else { return false }
        for home in frequent where haversine(lat, lon, home.latitude, home.longitude) <= params.homeDistanceMeters {
            return false
        }
        return true   // frequent が空（バラけた写真）なら away 扱い
    }

    // MARK: - Draft

    private func makeDraft(from run: [EnrichedPhoto], params: AlbumGenParams, homeCountry: String?) -> GeneratedAlbumDraft? {
        let members = run.filter { !$0.isScreenshot }   // スクショ除外
        guard members.count >= params.minTripPhotos else { return nil }

        let dates = members.compactMap(\.captureDate)
        let start = dates.min() ?? .distantPast
        let end = dates.max() ?? .distantPast

        let places = rankedByFrequency(members.compactMap(\.placeName))
        let memberCountry = mostCommonCountry(members)
        let country = (memberCountry != nil && memberCountry != homeCountry) ? memberCountry : nil
        let people = rankedByFrequency(members.flatMap(\.people))

        let located = members.filter(\.hasCoordinate)
        let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
        let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)

        return GeneratedAlbumDraft(
            strategyID: id, placeName: places.first, places: places, country: country,
            startDate: start, endDate: end, memberRefs: members.map(\.id),
            coverRef: pickCoverRef(members), people: people, latitude: lat, longitude: lon)
    }

    private func mostCommonCountry(_ members: [EnrichedPhoto]) -> String? {
        rankedByFrequency(members.compactMap(\.country)).first
    }
}

// MARK: - Geo helpers (純・テスト対象)

/// UTC 基準の日番号（異なる日数カウント用。ロケール/タイムゾーン非依存で決定的）。
func dayBucket(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

/// 2 点間の距離（メートル）。
func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let earth = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + sin(dLon / 2) * sin(dLon / 2) * cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
    return 2 * earth * asin(min(1, sqrt(a)))
}
