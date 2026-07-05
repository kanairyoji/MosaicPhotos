import CoreLocation
import Foundation
import ImageIO
import MosaicSupport
import Photos
import PhotoSourceKit

/// ローカル/クラウド写真を `EnrichedPhoto`（時間・座標・地名）に変換する。座標はローカルなら
/// `PHAsset.location`→EXIF、クラウドなら media_info 由来（CloudPhotoMeta）。地名は `PlaceNameResolver`
/// （グリッド単位キャッシュ）。既にエンリッチ済みの refKey はスキップし、現存 refKey 集合も返す（prune 用）。
struct PhotoEnricher {

    /// ローカル写真。返り値: (新規エンリッチ, 現存する全 refKey)。
    /// `peopleMap`（localId → 人物名）が与えられれば人物情報も付与する。
    func enrichLocal(existing: Set<String>, peopleMap: [String: [String]] = [:]) async -> (new: [EnrichedPhoto], current: Set<String>) {
        let fetched = await Task.detached(priority: .utility) {
            fetchNewLocalPhotos(existing: existing)
        }.value

        var newPhotos: [EnrichedPhoto] = []
        newPhotos.reserveCapacity(fetched.newRaws.count)
        for raw in fetched.newRaws {
            let place = await geocode(raw.latitude, raw.longitude)
            let country = await countryName(raw.latitude, raw.longitude)
            newPhotos.append(EnrichedPhoto(
                id: PhotoRef.local(raw.localIdentifier).encoded, captureDate: raw.captureDate,
                latitude: raw.latitude, longitude: raw.longitude, placeName: place, country: country,
                linkKey: nil, isScreenshot: raw.isScreenshot, isFavorite: raw.isFavorite,
                aspect: raw.aspect, people: peopleMap[raw.localIdentifier] ?? []))
        }
        await PlaceNameResolver.shared.persist()
        return (newPhotos, fetched.allRefKeys)
    }

    /// クラウド写真。返り値: (新規エンリッチ, 現存する全 refKey)。linkKey はクラウド自身の path。
    func enrichCloud(metas: [CloudPhotoMeta], existing: Set<String>) async -> (new: [EnrichedPhoto], current: Set<String>) {
        var current = Set<String>()
        var newPhotos: [EnrichedPhoto] = []
        for meta in metas {
            let refKey = PhotoRef.cloud(meta.path).encoded
            current.insert(refKey)
            guard !existing.contains(refKey) else { continue }
            let place = await geocode(meta.latitude, meta.longitude)
            let country = await countryName(meta.latitude, meta.longitude)
            newPhotos.append(EnrichedPhoto(
                id: refKey, captureDate: CaptureDate.meaningful(meta.captureDate), latitude: meta.latitude,
                longitude: meta.longitude, placeName: place, country: country, linkKey: meta.path))
        }
        await PlaceNameResolver.shared.persist()
        return (newPhotos, current)
    }

    private func geocode(_ lat: Double?, _ lon: Double?) async -> String? {
        guard let lat, let lon else { return nil }
        return await PlaceNameResolver.shared.cityName(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func countryName(_ lat: Double?, _ lon: Double?) async -> String? {
        guard let lat, let lon else { return nil }
        return await PlaceNameResolver.shared.countryName(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    /// ユーザー作成 iPhone アルバムに属する localIdentifier 集合（dedup 設定が ON のときに使う）。
    static func userAlbumedIdentifiers() async -> Set<String> {
        await Task.detached(priority: .utility) {
            var ids = Set<String>()
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            }
            return ids
        }.value
    }
}

private struct RawLocalPhoto: Sendable {
    let localIdentifier: String
    let captureDate: Date?
    let latitude: Double?
    let longitude: Double?
    let isScreenshot: Bool
    let isFavorite: Bool
    let aspect: Double?
}

/// 画像アセットを撮影日時降順で列挙。新規（existing に無い）のみ座標を解決し、現存 refKey 集合も返す。
private func fetchNewLocalPhotos(existing: Set<String>) -> (newRaws: [RawLocalPhoto], allRefKeys: Set<String>) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return ([], []) }

    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let result = PHAsset.fetchAssets(with: options)

    var allRefKeys = Set<String>()
    var newRaws: [RawLocalPhoto] = []
    result.enumerateObjects { asset, _, _ in
        // T4: EXIF 読みは元データを同期取得するため、autoreleasepool で 1 アセットごとに解放
        //（初回エンリッチのメモリスパイク対策・PlaceScanner と同型）。
        autoreleasepool {
            let id = asset.localIdentifier
            let refKey = "L-\(id)"
            allRefKeys.insert(refKey)
            guard !existing.contains(refKey) else { return }   // 既存は座標解決をスキップ
            var lat: Double?
            var lon: Double?
            if let location = asset.location {
                lat = location.coordinate.latitude
                lon = location.coordinate.longitude
            } else if let gps = readAssetExifGPS(asset) {
                lat = gps.latitude
                lon = gps.longitude
            }
            let aspect = asset.pixelHeight > 0 ? Double(asset.pixelWidth) / Double(asset.pixelHeight) : nil
            newRaws.append(RawLocalPhoto(
                localIdentifier: id, captureDate: CaptureDate.meaningful(asset.creationDate), latitude: lat, longitude: lon,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isFavorite: asset.isFavorite, aspect: aspect))
        }
    }
    return (newRaws, allRefKeys)
}

/// アセットの元データから EXIF/GPS を読み取る（画像はデコードせずメタデータのみ）。
private func readAssetExifGPS(_ asset: PHAsset) -> (latitude: Double, longitude: Double)? {
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.isNetworkAccessAllowed = false
    options.deliveryMode = .fastFormat
    options.version = .current

    var found: (latitude: Double, longitude: Double)?
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return }
        found = parseExifGPS(gps)
    }
    return found
}
