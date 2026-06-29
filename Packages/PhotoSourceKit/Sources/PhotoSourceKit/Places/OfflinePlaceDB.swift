import Foundation

/// 同梱した都市座標表（GeoNames cities15000・約3.4万件）で、座標 → 地名を**完全オフライン・即時**に
/// 最近傍検索する。`CLGeocoder` のオンライン依存・レート制限・失敗キャッシュ問題を回避するための実体。
/// `PlaceNameResolver` の一次バックエンドとして使う。
///
/// データ: GeoNames (https://www.geonames.org/) — CC BY 4.0。生成は `scripts/build_places.py`。
public final class OfflinePlaceDB: @unchecked Sendable {
    public static let shared = OfflinePlaceDB()

    public struct Place: Sendable {
        public let city: String?
        public let admin: String?     // 都道府県 / 州
        public let country: String?
    }

    private let lat: [Float]
    private let lon: [Float]
    private let adminIdx: [UInt16]
    private let countryIdx: [UInt16]
    private let adminPool: [String]
    private let countryPool: [String]
    private let cityNames: [String]
    private let count: Int

    /// 最近傍がこの距離より遠ければ「地名なし」（海上・極地など）とみなす。
    private static let maxMeters: Double = 500_000

    private init() {
        guard let url = Bundle.module.url(forResource: "cities15000", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let parsed = Self.parse(data) else {
            lat = []; lon = []; adminIdx = []; countryIdx = []
            adminPool = []; countryPool = []; cityNames = []; count = 0
            return
        }
        (lat, lon, adminIdx, countryIdx, adminPool, countryPool, cityNames) = parsed
        count = lat.count
    }

    public var isLoaded: Bool { count > 0 }

    /// 最近傍の都市から地名を返す。圏外（遠すぎ）や未ロードなら nil。
    public func nearest(latitude: Double, longitude: Double) -> Place? {
        guard count > 0,
              latitude.isFinite, longitude.isFinite else { return nil }
        // ランキングは等距円筒近似（経度は cos 補正）で十分。最後に最近傍だけ正確距離で圏外判定。
        let qLatF = Float(latitude), qLonF = Float(longitude)
        let cosLat = Float(cos(latitude * .pi / 180))
        var best = -1
        var bestD = Float.greatestFiniteMagnitude
        lat.withUnsafeBufferPointer { la in
            lon.withUnsafeBufferPointer { lo in
                for i in 0..<count {
                    let dx = (lo[i] - qLonF) * cosLat
                    let dy = la[i] - qLatF
                    let d = dx * dx + dy * dy
                    if d < bestD { bestD = d; best = i }
                }
            }
        }
        guard best >= 0,
              haversine(latitude, longitude, Double(lat[best]), Double(lon[best])) <= Self.maxMeters
        else { return nil }
        let admin = adminPool[safe: Int(adminIdx[best])].flatMap { $0.isEmpty ? nil : $0 }
        let country = countryPool[safe: Int(countryIdx[best])].flatMap { $0.isEmpty ? nil : $0 }
        return Place(city: cityNames[best], admin: admin, country: country)
    }

    // MARK: - Parsing

    private typealias Parsed = ([Float], [Float], [UInt16], [UInt16], [String], [String], [String])

    private static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        var i = 0
        func u8() -> Int { defer { i += 1 }; return Int(bytes[i]) }
        func u16() -> Int { let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2; return v }
        func u32() -> Int {
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4; return v
        }
        func f32() -> Float { Float(bitPattern: UInt32(u32())) }
        func str() -> String {
            let len = u16()
            let s = String(decoding: bytes[i..<i + len], as: UTF8.self)
            i += len; return s
        }

        guard bytes.count >= 12,
              bytes[0] == 0x4D, bytes[1] == 0x50, bytes[2] == 0x43, bytes[3] == 0x31 else { return nil } // "MPC1"
        i = 4
        _ = u32()                          // version
        let n = u32()
        guard n > 0, bytes.count > 12 + n * 12 else { return nil }

        var la = [Float](); la.reserveCapacity(n)
        var lo = [Float](); lo.reserveCapacity(n)
        for _ in 0..<n { la.append(f32()) }
        for _ in 0..<n { lo.append(f32()) }
        var ai = [UInt16](); ai.reserveCapacity(n)
        var ci = [UInt16](); ci.reserveCapacity(n)
        for _ in 0..<n { ai.append(UInt16(u16())) }
        for _ in 0..<n { ci.append(UInt16(u16())) }

        let adminCount = u16()
        var adminPool = [String](); adminPool.reserveCapacity(adminCount)
        for _ in 0..<adminCount { adminPool.append(str()) }
        let countryCount = u16()
        var countryPool = [String](); countryPool.reserveCapacity(countryCount)
        for _ in 0..<countryCount { countryPool.append(str()) }

        var names = [String](); names.reserveCapacity(n)
        for _ in 0..<n { names.append(str()) }

        return (la, lo, ai, ci, adminPool, countryPool, names)
    }
}

private func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let earth = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + sin(dLon / 2) * sin(dLon / 2) * cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
    return 2 * earth * asin(min(1, sqrt(a)))
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
