#if canImport(UIKit)
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// `get_thumbnail_batch` 1 チャンク分のネットワーク取得・画像デコード・キャッシュ書き込みを担う
/// I/O ユニット。キューイング戦略（`DropboxThumbnailBatcher`）から分離し、DTO と
/// エンコード/デコードは `DropboxThumbnailBatchRequest`（純ロジック）に委譲する。
@MainActor
struct DropboxThumbnailChunkFetcher {
    let apiClient: DropboxAPIClient
    let cache: DropboxCacheStore

    /// items を 1 リクエストで取得し、各 path の結果（成功=画像 / 失敗=nil）を `deliver` へ配送する。
    /// 取得成功分はキャッシュへも書き込む（待機者が居ない先読みでも、後からの要求が即ヒットする）。
    func fetch(_ items: [DropboxFileItem], deliver: (UIImage?, String) -> Void) async {
        let paths = items.map(\.path)
        guard let body = DropboxThumbnailBatchRequest.encodeBody(paths: paths) else {
            paths.forEach { deliver(nil, $0) }
            return
        }
        // 認証ヘッダ付与・POST・ステータス検証は DropboxAPIClient に委譲。
        guard let data = try? await apiClient.rpc(url: DropboxInternalConstants.getThumbnailBatchURL, jsonBody: body),
              let results = DropboxThumbnailBatchRequest.decodeResults(from: data, paths: paths) else {
            DropboxLogger.error("fetchThumbnailChunk() batch request failed (\(items.count) items)")
            paths.forEach { deliver(nil, $0) }
            return
        }

        // 成功エントリの base64 復号済み Data を集め、成功しなかったものは即 nil 配送。
        var decodeInputs: [(path: String, data: Data)] = []
        for entry in results {
            if let imgData = entry.imageData {
                decodeInputs.append((entry.path, imgData))
            } else {
                deliver(nil, entry.path)
            }
        }

        // ★ 画像デコード（強制）をバックグラウンドで実行し、メインの負荷を避ける。
        // 並行数はバッチ並行数（maxConcurrentThumbnailRequests）で既に有界なので、ディスクデコード用の
        // ThumbnailDecode.limiter は通さない（ディスク再デコードを待たせない＝分離）。
        // 計測: 1 チャンク分のデコード所要と件数（ネットワークは net.* で別途計測済み）。
        let tDecode = PerfTrace.nowNs()
        // デコードは `.utility`（UI=userInteractive・遷移より低い）に下げ、メインスレッド/遷移を
        // 飢餓させない。サムネ表示は僅かに遅れても、スクロール・画面遷移の手応えを優先する。
        let decoded: [(String, SendableUIImage?)] = await Task.detached(priority: .utility) {
            decodeInputs.map { input in
                let image = UIImage(data: input.data).map { $0.preparingForDisplay() ?? $0 }
                return (input.path, image.map(SendableUIImage.init))
            }
        }.value
        PerfTrace.count("thumb.decodeMs", value: PerfTrace.msSince(tDecode))
        PerfTrace.count("thumb.decodedItems", value: Double(decodeInputs.count))

        for (path, sendable) in decoded {
            let image = sendable?.image
            if let image { await cache.storeThumbnail(image, for: path) }
            deliver(image, path)
        }
        DropboxLogger.verbose("fetchThumbnailChunk() \(items.count) items in 1 request")
    }
}
#endif
