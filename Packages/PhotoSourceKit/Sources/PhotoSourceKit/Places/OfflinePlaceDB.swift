import Foundation

/// 同梱した都市座標表（GeoNames cities15000・約3.4万件）で、座標 → 地名を**完全オフライン・即時**に
/// 最近傍検索する。`CLGeocoder` のオンライン依存・レート制限・失敗キャッシュ問題を回避するための実体。
/// `PlaceNameResolver` の一次バックエンドとして使う。
///
/// 地名は**英語（ローマ字）と日本語**の両方を保持し、`japanese` 引数で切り替える（日本語が無い都市は
/// 英語へフォールバック）。データ: GeoNames (https://www.geonames.org/) — CC BY 4.0。生成は
/// `scripts/build_places.py`。
public final class OfflinePlaceDB: @unchecked Sendable {
    public static let shared = OfflinePlaceDB()

    public struct Place: Sendable {
        public let city: String?
        public let admin: String?     // 都道府県 / 州
        public let country: String?
    }

    private let lat: [Float]
    private let lon: [Float]
    private let cityEn: [String]
    private let cityJa: [String]      // 空＝英語へフォールバック
    private let adminEnPool: [String]
    private let adminJaPool: [String]
    private let adminEnIdx: [UInt16]
    private let adminJaIdx: [UInt16]
    private let countryEnPool: [String]
    private let countryJaPool: [String]
    private let countryEnIdx: [UInt16]
    private let countryJaIdx: [UInt16]
    private let count: Int

    /// 最近傍がこの距離より遠ければ「地名なし」（海上・極地など）とみなす。
    private static let maxMeters: Double = 500_000

    private init() {
        guard let url = Bundle.module.url(forResource: "cities15000", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let p = Self.parse(data) else {
            lat = []; lon = []; cityEn = []; cityJa = []
            adminEnPool = []; adminJaPool = []; adminEnIdx = []; adminJaIdx = []
            countryEnPool = []; countryJaPool = []; countryEnIdx = []; countryJaIdx = []
            count = 0
            return
        }
        lat = p.lat; lon = p.lon; cityEn = p.cityEn; cityJa = p.cityJa
        adminEnPool = p.adminEnPool; adminJaPool = p.adminJaPool
        adminEnIdx = p.adminEnIdx; adminJaIdx = p.adminJaIdx
        countryEnPool = p.countryEnPool; countryJaPool = p.countryJaPool
        countryEnIdx = p.countryEnIdx; countryJaIdx = p.countryJaIdx
        count = lat.count
    }

    public var isLoaded: Bool { count > 0 }

    /// 最近傍の都市から地名を返す。`japanese` で表示言語を選ぶ（日本語が無ければ英語へフォールバック）。
    /// 圏外（遠すぎ）や未ロードなら nil。
    public func nearest(latitude: Double, longitude: Double, japanese: Bool) -> Place? {
        guard count > 0, latitude.isFinite, longitude.isFinite else { return nil }
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

        func choose(_ ja: String, _ en: String) -> String? {
            let s = (japanese && !ja.isEmpty) ? ja : en
            return s.isEmpty ? nil : s
        }
        let cityJaS = cityJa[best]
        let city = choose(cityJaS, cityEn[best])
        let admin = choose(adminJaPool[safe: Int(adminJaIdx[best])] ?? "",
                           adminEnPool[safe: Int(adminEnIdx[best])] ?? "")
        let country = choose(countryJaPool[safe: Int(countryJaIdx[best])] ?? "",
                             countryEnPool[safe: Int(countryEnIdx[best])] ?? "")
        return Place(city: city, admin: admin, country: country)
    }

    // MARK: - Parsing

    private struct Parsed {
        let lat: [Float], lon: [Float], cityEn: [String], cityJa: [String]
        let adminEnPool: [String], adminJaPool: [String], adminEnIdx: [UInt16], adminJaIdx: [UInt16]
        let countryEnPool: [String], countryJaPool: [String], countryEnIdx: [UInt16], countryJaIdx: [UInt16]
    }

    private static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        var i = 0
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
        func floats(_ n: Int) -> [Float] { var a = [Float](); a.reserveCapacity(n); for _ in 0..<n { a.append(f32()) }; return a }
        func u16s(_ n: Int) -> [UInt16] { var a = [UInt16](); a.reserveCapacity(n); for _ in 0..<n { a.append(UInt16(u16())) }; return a }
        func pool() -> [String] { let c = u16(); var a = [String](); a.reserveCapacity(c); for _ in 0..<c { a.append(str()) }; return a }
        func strs(_ n: Int) -> [String] { var a = [String](); a.reserveCapacity(n); for _ in 0..<n { a.append(str()) }; return a }

        guard bytes.count >= 12,
              bytes[0] == 0x4D, bytes[1] == 0x50, bytes[2] == 0x43, bytes[3] == 0x32 else { return nil } // "MPC2"
        i = 4
        _ = u32()                          // version
        let n = u32()
        guard n > 0, bytes.count > 12 + n * 12 else { return nil }

        let la = floats(n), lo = floats(n)
        let aen = u16s(n), aja = u16s(n), cen = u16s(n), cja = u16s(n)
        let aenP = pool(), ajaP = pool(), cenP = pool(), cjaP = pool()
        let cityEn = strs(n), cityJa = strs(n)
        return Parsed(lat: la, lon: lo, cityEn: cityEn, cityJa: cityJa,
                      adminEnPool: aenP, adminJaPool: ajaP, adminEnIdx: aen, adminJaIdx: aja,
                      countryEnPool: cenP, countryJaPool: cjaP, countryEnIdx: cen, countryJaIdx: cja)
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
