#if canImport(UIKit)
import CoreLocation
import DropboxKit
import Foundation
import ImageIO
import Photos
import PhotoSourceKit

/// 市区町村ごとに写真をまとめる「場所」スキャナ。ローカル（PHAsset の位置情報）と
/// Dropbox（同期済み media_info の座標）を集約し、逆ジオコーディングでグルーピングする。
///
/// ローカルの位置情報は `PHAsset.location` を第一とし、nil（シミュレータへコピーした写真や
/// 取り込み画像で索引されていない場合）は EXIF の GPS を直接読み取って補完する。
/// グリッドキー（`GeoGridKey`）・グルーピング（`PlaceGrouping`）・永続化（`JSONFileStore`）は
/// PhotoSourceKit の共通部品に委譲し、本型は「収集 → ジオコード → 段階表示」の制御に専念する。
@MainActor
@Observable
public final class PlaceScanner {

    public private(set) var places: [PlaceAlbumInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isScanning = false

    private let store = JSONFileStore<[PlaceAlbumInfo]>(filename: "Places/placeIndex.json")

    /// EXIF から抽出したローカル写真の GPS を localIdentifier 単位でキャッシュ（再読込回避）。
    /// 値が「lat/lon ともに nil」のエントリは「読み取り済み・GPS 無し」を意味する。
    private let localGPSStore = JSONFileStore<[String: CachedGPS]>(filename: "Places/localGPS.json")
    private var localGPSCache: [String: CachedGPS]

    /// 最後にスキャンした「座標付き Dropbox アイテム集合」の署名。
    private var lastScanSignature: Int = 0

    /// ローカル写真ライブラリに変化があったか（PHPhotoLibraryChangeObserver が立てる）。
    private var localLibraryDirty = false
    private var libraryObserver: PhotoLibraryObserver?

    /// 直近に渡された Dropbox アイテム集合。設定からの手動 `rescan()` で再利用する。
    private var lastDropboxItems: [DropboxFileItem] = []

    public init() {
        localGPSCache = localGPSStore.load() ?? [:]
    }

    /// 位置情報付き写真の合計枚数（設定表示用）。
    public var photoCount: Int { places.reduce(0) { $0 + $1.photoCount } }

    /// グルーピングのグリッド粒度（度）。設定が無ければ `GeoGridKey.defaultStep`。
    private var gridStep: Double {
        let v = UserDefaults.standard.double(forKey: PlacesSettingsKeys.gridStepDegrees)
        return v > 0 ? v : GeoGridKey.defaultStep
    }

    /// 場所インデックス・逆ジオコーディング・ローカル GPS のキャッシュをすべて消去する（Debug 用）。
    public func clearCache() async {
        places = []
        lastScanSignature = 0
        localGPSCache = [:]
        store.save([])
        localGPSStore.save([:])
        await PlaceNameResolver.shared.clearCache()
    }

    // MARK: - Public API

    public func loadOrScan(dropboxItems: [DropboxFileItem]) async {
        lastDropboxItems = dropboxItems
        ensureLibraryObserver()
        if places.isEmpty, let cached = store.load() {
            places = cached
        }
        isLoaded = true
        if places.isEmpty {
            await scan(dropboxItems: dropboxItems)
        }
    }

    /// Dropbox の座標集合が変化、またはローカルライブラリに変化があれば再スキャンする。
    /// どちらも無ければ即 return（安価）。HomeView から定期的に呼ぶ。
    public func refreshIfNeeded(dropboxItems: [DropboxFileItem]) async {
        lastDropboxItems = dropboxItems
        guard isLoaded, !isScanning else { return }
        // 署名計算（67k のハッシュ XOR）も毎ティック・メインで回さずオフメインで。
        let signature = await Task.detached(priority: .utility) { placeScanSignature(dropboxItems) }.value
        guard signature != lastScanSignature || localLibraryDirty else { return }
        localLibraryDirty = false
        await scan(dropboxItems: dropboxItems)
    }

    /// 直近の Dropbox アイテム集合で再スキャンする（設定の「Rescan now」用）。
    public func rescan() async {
        localLibraryDirty = false
        await scan(dropboxItems: lastDropboxItems)
    }

    public func scan(dropboxItems: [DropboxFileItem]) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; isLoaded = true }

        // 初回（places 空）は地名解決の都度 publish して段階表示する。
        // 再スキャンは地名キャッシュ済みで高速なので、無瞬断のため最後に一括反映する。
        let incremental = places.isEmpty

        // 0. 写真アクセス権を確認（未決定なら要求）。Places は他ソースを開かなくても動くようにする。
        let authStatus = await ensurePhotoAuthorization()
        _ = authStatus

        // 1. ローカル候補収集（座標付き）。バックグラウンドで列挙し、EXIF キャッシュを更新する。
        let snapshot = localGPSCache
        let local = await Task.detached(priority: .utility) {
            fetchLocalLocatedCandidates(exifCache: snapshot)
        }.value
        localGPSCache = local.cache
        localGPSStore.save(local.cache)

        // 2. クラウド候補抽出（67k 件の compactMap）・グリッド集約・署名計算を **オフメイン**で行う
        //    （メインスレッドで 67k を回すと起動・定期スキャンでカクつくため）。
        let step = gridStep
        let localCandidates = local.candidates
        let (signature, byGrid) = await Task.detached(priority: .utility) {
            () -> (Int, [String: [PlaceCandidate]]) in
            let sig = placeScanSignature(dropboxItems)
            let cloud = dropboxItems.compactMap { item -> PlaceCandidate? in
                guard let coordinate = item.coordinate else { return nil }
                return PlaceCandidate(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                      isLocal: false, identifier: item.path, date: item.captureDate)
            }
            var grid: [String: [PlaceCandidate]] = [:]
            for candidate in localCandidates + cloud {
                grid[GeoGridKey.key(latitude: candidate.latitude, longitude: candidate.longitude, step: step),
                     default: []].append(candidate)
            }
            return (sig, grid)
        }.value

        guard !byGrid.isEmpty else {
            places = []
            lastScanSignature = signature
            return
        }

        // 3. ユニークキーを逐次ジオコーディングし、市区町村ごとに集約。
        var byCity: [String: [PlaceCandidate]] = [:]
        for (_, group) in byGrid {
            guard let first = group.first else { continue }
            let representative = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
            let city = await PlaceNameResolver.shared.cityName(for: representative)
            byCity[city ?? "Unknown", default: []].append(contentsOf: group)
            if incremental { places = PlaceGrouping.build(byCity: byCity) }   // 段階表示
        }
        if !incremental { places = PlaceGrouping.build(byCity: byCity) }      // 一括反映（無瞬断）

        await PlaceNameResolver.shared.persist()
        store.save(places)
        lastScanSignature = signature
    }

    /// 写真ライブラリのアクセス権を確認し、未決定なら要求する。
    private func ensurePhotoAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Photo library change observation

    private func ensureLibraryObserver() {
        guard libraryObserver == nil else { return }
        let observer = PhotoLibraryObserver { [weak self] in
            Task { @MainActor in self?.localLibraryDirty = true }
        }
        libraryObserver = observer
        PHPhotoLibrary.shared().register(observer)
    }
}

// MARK: - Local GPS cache value

/// EXIF から抽出した GPS のキャッシュ値。lat/lon ともに nil = 読み取り済みだが GPS 無し。
struct CachedGPS: Codable, Sendable {
    let lat: Double?
    let lon: Double?
}

// MARK: - Photo library observer (NSObject 必須)

private final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

// MARK: - Pure signature (top-level・テスト対象)

/// 座標付き Dropbox アイテムのパス集合の署名。並び順に依存しない（XOR）。
func placeScanSignature(_ items: [DropboxFileItem]) -> Int {
    var signature = 0
    for item in items where item.coordinate != nil {
        signature ^= item.path.hashValue
    }
    return signature
}

// MARK: - Local enumeration (top-level for Task.detached)

/// 位置情報付きのローカル画像アセットを列挙する。`PHAsset.location` を優先し、nil の場合は
/// EXIF の GPS を読み取って補完する（EXIF 読み取り結果は `exifCache` で localIdentifier 単位に
/// キャッシュし、再スキャン時の重複 I/O を避ける）。更新後のキャッシュも返す。
/// Task.detached から呼ぶため top-level 関数。
private func fetchLocalLocatedCandidates(
    exifCache: [String: CachedGPS]
) -> (candidates: [PlaceCandidate], cache: [String: CachedGPS]) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return ([], exifCache) }

    var cache = exifCache
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let result = PHAsset.fetchAssets(with: options)

    var candidates: [PlaceCandidate] = []
    result.enumerateObjects { asset, _, _ in
        let id = asset.localIdentifier
        var coordinate: CLLocationCoordinate2D?

        if let location = asset.location {
            coordinate = location.coordinate
        } else {
            // PHAsset.location が無い → EXIF を読む（キャッシュ優先）。
            let gps: CachedGPS
            if let cached = cache[id] {
                gps = cached
            } else {
                gps = readExifGPS(for: asset)
                cache[id] = gps
            }
            if let lat = gps.lat, let lon = gps.lon {
                coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }

        guard let c = coordinate else { return }
        candidates.append(PlaceCandidate(
            latitude: c.latitude, longitude: c.longitude,
            isLocal: true, identifier: id, date: asset.creationDate))
    }
    return (candidates, cache)
}

/// アセットの元データから EXIF/GPS の緯度経度を読み取る（画像はデコードせずメタデータのみ）。
private func readExifGPS(for asset: PHAsset) -> CachedGPS {
    let options = PHImageRequestOptions()
    options.isSynchronous = true            // Task.detached（非メイン）上で同期取得
    options.isNetworkAccessAllowed = false  // iCloud 専用は対象外
    options.deliveryMode = .fastFormat
    options.version = .current

    var found = CachedGPS(lat: nil, lon: nil)
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return }
        found = parseGPSCoordinate(gps)
    }
    return found
}

/// GPS 辞書（ImageIO）から符号付き緯度経度を取り出す。実体は PhotoSourceKit の共有純関数
/// `parseExifGPS` に委譲する（CachedGPS 形へ変換するだけ）。
func parseGPSCoordinate(_ gps: [CFString: Any]) -> CachedGPS {
    guard let c = parseExifGPS(gps) else { return CachedGPS(lat: nil, lon: nil) }
    return CachedGPS(lat: c.latitude, lon: c.longitude)
}
#endif
