import CoreLocation
import Foundation
import MosaicSupport

/// 逆ジオコーディング結果の主要コンポーネント（永続キャッシュ用）。
/// `subLocality`/`refined` は後付け（optional）＝旧キャッシュ JSON はキー欠落で nil に decode され互換。
public struct PlaceComponents: Codable, Sendable, Equatable {
    public let locality: String?
    /// 区・町名など（CLGeocoder のみ・オフライン都市 DB では取れない）。
    public let subLocality: String?
    public let administrativeArea: String?
    public let country: String?
    /// Apple（CLGeocoder）で高精度化済みか。オフラインの粗い結果（nil/false）は背景で上書き対象。
    public let refined: Bool?

    public init(locality: String?, subLocality: String? = nil,
                administrativeArea: String?, country: String?, refined: Bool? = nil) {
        self.locality = locality
        self.subLocality = subLocality
        self.administrativeArea = administrativeArea
        self.country = country
        self.refined = refined
    }

    public var isEmpty: Bool {
        locality == nil && subLocality == nil && administrativeArea == nil && country == nil
    }
    public var isRefined: Bool { refined == true }
}

/// 座標 → 地名（逆ジオコーディング）の解決器。**同梱の都市DB（`OfflinePlaceDB`）で完全オフライン**に
/// 最近傍解決する（旧 `CLGeocoder` はオンライン依存・レート制限・失敗の恒久キャッシュで「Trip」固定の
/// 原因になっていたため廃止）。座標は粗いグリッドキーでキャッシュし、ディスクへ永続化する。
public actor PlaceNameResolver {
    public static let shared = PlaceNameResolver()

    private var cache: [String: PlaceComponents]
    private let store = JSONFileStore<[String: PlaceComponents]>(filename: "PhotoSourceKit/placeNames.json")

    /// オフライン解決ロジックの版。上げると **refined でない**キャッシュだけ破棄して再解決させる
    /// （Apple 解決済みは維持）。v2: 距離格下げ（遠い最近傍は市名を捨てる）導入。
    private static let offlineLogicVersion = 2
    private static let offlineLogicVersionKey = "PhotoSourceKit.offlineResolveVersion"

    /// Apple 補正でキャッシュが更新されるたびに増える世代。場所スキャナ等が
    /// 「地名が変わったので作り直すべきか」の判定に使う（永続不要＝起動直後の初回スキャンが拾う）。
    public private(set) var refinementGeneration = 0

    public init() {
        var loaded = store.load() ?? [:]
        // オフライン解決ロジックが変わったら、オフライン由来（refined でない）の項だけ捨てて再解決させる。
        let stored = UserDefaults.standard.integer(forKey: Self.offlineLogicVersionKey)
        if stored < Self.offlineLogicVersion, !loaded.isEmpty {
            loaded = loaded.filter { $0.value.isRefined }
        }
        UserDefaults.standard.set(Self.offlineLogicVersion, forKey: Self.offlineLogicVersionKey)
        cache = loaded
    }

    /// 現在の表示言語のキャッシュキー接頭辞（"ja:"/"en:"）。台帳伝播の純ロジックと共有する。
    public static var keyPrefix: String { AppLocale.isJapanese ? "ja:" : "en:" }

    /// キャッシュ全体のスナップショット（台帳伝播の差分計算用・読み取り専用）。
    public func cachedComponentsSnapshot() -> [String: PlaceComponents] { cache }

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

    // MARK: - Apple（CLGeocoder）による背景高精度化

    /// 座標群の地名を **Apple の逆ジオコーディング（CLGeocoder）で高精度化**する。
    /// オフライン都市 DB は「最寄りの大都市へスナップ」で粗いため、区・町名（subLocality）や正確な
    /// 市区町村を Apple から取り込む。旧実装の失敗（レート制限・失敗の恒久固着）を避けるため:
    /// - **成功だけキャッシュを上書き**し（`refined=true`）、**失敗はキャッシュしない**（次回リトライ）。
    /// - 1 件ずつ `minInterval` 間隔で（レート制限回避）。呼び出し側は枚数の多いセル順に渡し、
    ///   1 回あたり `maxRequests` 件で打ち切る（数晩で全セルに収束し、以後はスキップ＝無コスト）。
    /// - 既に `refined` 済みのグリッドセルは飛ばす。`shouldContinue` が false で中断。
    /// 戻り値＝新たに高精度化できた地点数。0 なら表示更新は不要。
    public func refineWithAppleGeocoder(coordinates: [CLLocationCoordinate2D],
                                        maxRequests: Int = 300,
                                        minInterval: TimeInterval = 1.2,
                                        shouldContinue: @Sendable () async -> Bool = { true }) async -> Int {
        let ja = AppLocale.isJapanese
        let locale = Locale(identifier: ja ? "ja_JP" : "en_US")
        let geocoder = CLGeocoder()
        var refinedCount = 0
        var requests = 0
        var seenKeys = Set<String>()
        for coord in coordinates {
            guard await shouldContinue(), requests < maxRequests else { break }
            let key = (ja ? "ja:" : "en:") + GeoGridKey.key(coord)
            if seenKeys.contains(key) { continue }       // 同一グリッドセルは 1 回だけ
            seenKeys.insert(key)
            if cache[key]?.isRefined == true { continue } // 既に Apple 解決済み

            requests += 1
            let placemarks = try? await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coord.latitude, longitude: coord.longitude),
                preferredLocale: locale)
            if let p = placemarks?.first {
                let comp = PlaceComponents(locality: p.locality, subLocality: p.subLocality,
                                           administrativeArea: p.administrativeArea,
                                           country: p.country, refined: true)
                if !comp.isEmpty { cache[key] = comp; refinedCount += 1 }
            }
            // 失敗（ネット/レート制限/圏外）はキャッシュしない＝次回リトライ（旧「Trip 固定」を避ける）。
            try? await Task.sleep(nanoseconds: UInt64(minInterval * 1_000_000_000))
        }
        if refinedCount > 0 {
            store.save(cache)
            refinementGeneration += 1
        }
        return refinedCount
    }

    /// デバッグ: 1 座標を **CLGeocoder で直接**逆ジオコーディングして人間可読の地名を返す
    /// （キャッシュ・refined 判定を通さない＝Apple が実際に返す値そのもの・動作確認用）。取得不可は nil。
    public func debugGeocode(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let ja = AppLocale.isJapanese
        let locale = Locale(identifier: ja ? "ja_JP" : "en_US")
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            preferredLocale: locale)
        guard let p = placemarks?.first else { return nil }
        return [p.subLocality, p.locality, p.administrativeArea, p.country]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Private

    private func components(for coordinate: CLLocationCoordinate2D) async -> PlaceComponents? {
        // 地名はアプリの表示言語（日本語/英語）に追従させる。キャッシュも言語別に分ける。
        let ja = AppLocale.isJapanese
        let key = (ja ? "ja:" : "en:") + GeoGridKey.key(coordinate)
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }

        // オフラインの都市DBで最近傍解決（即時・無制限・失敗なし）。圏外（海上等）は空。
        let place = OfflinePlaceDB.shared.nearest(
            latitude: coordinate.latitude, longitude: coordinate.longitude, japanese: ja)
        let components = PlaceComponents(
            locality: place?.city,
            administrativeArea: place?.admin,
            country: place?.country
        )
        cache[key] = components   // オフラインは決定的なので空（圏外）も安全にキャッシュできる
        return components.isEmpty ? nil : components
    }
}
