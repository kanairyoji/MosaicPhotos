import CoreLocation
import Foundation

/// 逆ジオコーディング結果の主要コンポーネント（永続キャッシュ用）。
public struct PlaceComponents: Codable, Sendable, Equatable {
    public let locality: String?
    public let administrativeArea: String?
    public let country: String?

    public var isEmpty: Bool {
        locality == nil && administrativeArea == nil && country == nil
    }
}

/// 座標 → 地名（逆ジオコーディング）の解決器。**同梱の都市DB（`OfflinePlaceDB`）で完全オフライン**に
/// 最近傍解決する（旧 `CLGeocoder` はオンライン依存・レート制限・失敗の恒久キャッシュで「Trip」固定の
/// 原因になっていたため廃止）。座標は粗いグリッドキーでキャッシュし、ディスクへ永続化する。
public actor PlaceNameResolver {
    public static let shared = PlaceNameResolver()

    private var cache: [String: PlaceComponents]
    private let store = JSONFileStore<[String: PlaceComponents]>(filename: "PhotoSourceKit/placeNames.json")

    public init() {
        cache = store.load() ?? [:]
    }

    /// 詳細表示向け：市区町村, 州/県, 国 を連結した文字列。
    public func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        guard let components = await components(for: coordinate) else { return nil }
        let joined = [components.locality, components.administrativeArea, components.country]
            .compactMap { $0 }
            .joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// グルーピング向け：市区町村（無ければ州/県/国）。
    public func cityName(for coordinate: CLLocationCoordinate2D) async -> String? {
        guard let components = await components(for: coordinate) else { return nil }
        return components.locality ?? components.administrativeArea ?? components.country
    }

    /// 国名のみ（海外旅行判定・タイトル用）。
    public func countryName(for coordinate: CLLocationCoordinate2D) async -> String? {
        await components(for: coordinate)?.country
    }

    /// メモリ上のキャッシュをディスクへ保存する（スキャン完了時などに呼ぶ）。
    public func persist() {
        store.save(cache)
    }

    /// 逆ジオコーディングのキャッシュ（メモリ＋ディスク）を消去する（設定の Debug 用）。
    /// 次回スキャン時にすべて再ジオコーディングされる。
    public func clearCache() {
        cache = [:]
        store.save([:])
    }

    /// キャッシュ済みの地点数（設定表示用）。
    public var cachedPlaceCount: Int { cache.count }

    // MARK: - Private

    private func components(for coordinate: CLLocationCoordinate2D) async -> PlaceComponents? {
        let key = GeoGridKey.key(coordinate)
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }

        // オフラインの都市DBで最近傍解決（即時・無制限・失敗なし）。圏外（海上等）は空。
        let place = OfflinePlaceDB.shared.nearest(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let components = PlaceComponents(
            locality: place?.city,
            administrativeArea: place?.admin,
            country: place?.country
        )
        cache[key] = components   // オフラインは決定的なので空（圏外）も安全にキャッシュできる
        return components.isEmpty ? nil : components
    }
}
