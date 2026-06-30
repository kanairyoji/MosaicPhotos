#if canImport(UIKit)
import CoreLocation
import Foundation

/// `DropboxPhotoStore` の撮影地（座標）解決。同期時に取れた座標を優先し、必要時のみ
/// `get_metadata` で補完する。本体宣言は `DropboxPhotoStore.swift`。
extension DropboxPhotoStore {

    /// 撮影地の座標。同期時に取れていれば即返し、無ければ get_metadata で単発取得して補完・保存する。
    public func location(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        if let coordinate = item.coordinate { return coordinate }

        struct Arg: Encodable { let path: String; let include_media_info = true }
        guard let body = try? JSONEncoder().encode(Arg(path: item.path)),
              let data = try? await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL, jsonBody: body)
        else { return nil }

        struct Meta: Decodable { let media_info: DropboxMediaInfo? }
        guard let loc = (try? JSONDecoder().decode(Meta.self, from: data))?.media_info?.metadata?.location else {
            return nil
        }
        await cache.updateLocation(path: item.path, latitude: loc.latitude, longitude: loc.longitude)
        return CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
    }

    /// ネット取得を伴わない座標。同期時に取れていれば返し、無ければ nil（get_metadata は叩かない）。
    /// フル表示の場所ラベル用：開くたびの 4〜6s の get_metadata 往復を避ける。
    public func cachedLocation(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        item.coordinate
    }
}
#endif
