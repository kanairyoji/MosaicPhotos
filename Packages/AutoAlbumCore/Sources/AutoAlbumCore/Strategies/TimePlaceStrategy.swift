import Foundation
import PhotoSourceKit

/// 時間＋場所から「旅行・お出かけ」アルバムを抽出する戦略。
///
/// 1. **座標（位置情報）のある写真のみ**を対象にする（位置情報のない写真は旅行に含めない）。
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

        // ⚠️ 位置情報のない写真は旅行に含めない（時間的に近い GPS を借りる backfill は廃止）。
        // isAway は座標が無いと false を返すため、未測位写真は away にならず自然に除外される。
        let frequent = frequentLocations(sorted, params: params)
        let homeCountry = mostCommonCountry(sorted)

        // 日単位で「自宅外（away）写真」と「在宅日」を仕分ける。
        // 旅行 = 連続する away 日のまとまり。多日旅行を日ごとに分割しない（cohesion）が、
        // 在宅日を挟んだり大きく日が空いたら別の旅行に分ける。
        var awayByDay: [Int: [EnrichedPhoto]] = [:]
        var homeDays: Set<Int> = []
        for photo in sorted {
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
