import Foundation
import Photos

/// 写真本体の取得結果。
enum FetchDataResult {
    /// - `isEditedRendition`: 写真アプリの**編集結果**（`.fullSizePhoto`）を読んだか。
    ///   オフロードの skip 理由を「編集結果が未バックアップ」と言い分けるために持つ。
    case success(data: Data, filename: String, isEditedRendition: Bool)
    case skipped(filename: String, reason: String)
}

/// `PHAssetResource` からファイル名とバイナリを取得する。`BackupEngine` から分離した純粋な読み取り。
enum BackupAssetReader {

    /// 写真アセットの本体データを取得する。iCloud 専用（未ダウンロード）はスキップ。
    ///
    /// ⚠️ **写真アプリで「今」見えているものを読む**（ADR-168）。編集済みの写真は
    /// `.fullSizePhoto`（編集結果）を選び、`.photo`（原画）へは**フォールバックしない**——
    /// 原画に落とすと、上げたバイト列と端末の見た目が食い違い、オフロードの直前検証も
    /// 原画同士で一致してしまう（＝編集結果を残さないまま削除する）。編集レンディションが
    /// 端末に無い（iCloud 最適化）ときはこの 1 枚をスキップし、次回に委ねる。
    static func read(asset: PHAsset, fallback: String) async -> FetchDataResult {
        let resources = PHAssetResource.assetResources(for: asset)
        let descriptors = resources.map {
            BackupRenditionNaming.ResourceDescriptor(
                kind: kind(of: $0.type), originalFilename: $0.originalFilename,
                uniformTypeIdentifier: $0.uniformTypeIdentifier)
        }
        guard let selection = BackupRenditionNaming.select(descriptors) else {
            return .skipped(filename: fallback, reason: "no PHAssetResource found")
        }
        let resource = resources[selection.index]

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false  // iCloud 専用ファイルはスキップ

        let data: Data
        do {
            data = try await withCheckedThrowingContinuation({ (cont: CheckedContinuation<Data, Error>) in
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
        } catch {
            let name = resource.originalFilename.isEmpty ? fallback : resource.originalFilename
            return .skipped(filename: name, reason: error.localizedDescription)
        }

        // 名前は実データの形式まで見て決める（形式が定まらない編集結果は上げない）。
        guard let filename = BackupRenditionNaming.filename(
            resources: descriptors, selection: selection,
            localIdentifier: asset.localIdentifier, fallback: fallback, data: data) else {
            return .skipped(filename: fallback,
                            reason: "could not determine a safe filename for the edited version")
        }
        return .success(data: data, filename: filename, isEditedRendition: selection.isEdited)
    }

    private static func kind(of type: PHAssetResourceType) -> BackupRenditionNaming.ResourceKind {
        switch type {
        case .photo:         return .photo
        case .fullSizePhoto: return .fullSizePhoto
        default:             return .other
        }
    }
}
