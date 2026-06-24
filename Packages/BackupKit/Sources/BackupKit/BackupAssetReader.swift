import Foundation
import Photos

/// 写真本体の取得結果。
enum FetchDataResult {
    case success(data: Data, filename: String)
    case skipped(filename: String, reason: String)
}

/// `PHAssetResource` からファイル名とバイナリを取得する。`BackupEngine` から分離した純粋な読み取り。
enum BackupAssetReader {

    /// 写真アセットの本体データを取得する。iCloud 専用（未ダウンロード）はスキップ。
    static func read(asset: PHAsset, fallback: String) async -> FetchDataResult {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
                          ?? resources.first(where: { $0.type == .fullSizePhoto })
                          ?? resources.first
        else {
            return .skipped(filename: fallback, reason: "no PHAssetResource found")
        }

        let filename = resource.originalFilename.isEmpty ? fallback : resource.originalFilename

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false  // iCloud 専用ファイルはスキップ

        do {
            let data = try await withCheckedThrowingContinuation({ (cont: CheckedContinuation<Data, Error>) in
                var buffer = Data()
                PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: opts,
                    dataReceivedHandler: { buffer.append($0) },
                    completionHandler: { err in
                        if let err { cont.resume(throwing: err) }
                        else { cont.resume(returning: buffer) }
                    }
                )
            })
            return .success(data: data, filename: filename)
        } catch {
            return .skipped(filename: filename, reason: error.localizedDescription)
        }
    }
}
