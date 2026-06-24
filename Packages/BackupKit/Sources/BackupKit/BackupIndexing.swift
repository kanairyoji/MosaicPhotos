import Photos

// MARK: - PHAuthorizationStatus debug description

extension PHAuthorizationStatus {
    var debugDescription: String {
        switch self {
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}

// MARK: - Index builders (top-level, safe for Task.detached)

// ⚠️ buildPeopleIndex / buildAlbumIndex はトップレベル関数である必要がある。
// インスタンスメソッドとして定義すると Task.detached クロージャ内でコンパイラが
// @MainActor 型の self を捕捉しようとしてコンパイルエラーになる（過去に発生）。

func buildAlbumIndex() -> [String: [String]] {
    var index: [String: [String]] = [:]
    let collections = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .albumRegular, options: nil)
    collections.enumerateObjects { collection, _, _ in
        guard let name = collection.localizedTitle, !name.isEmpty else { return }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        assets.enumerateObjects { asset, _, _ in
            index[asset.localIdentifier, default: []].append(name)
        }
    }
    return index
}

// ⚠️ PHAssetCollectionSubtype.albumFaces は iOS 17 SDK に名前付き定数が存在しないため
// rawValue: 1000 で代替する。また PHAssetCollectionSubtype(rawValue:) は Optional を返すため
// guard let が必須（unwrap 忘れでコンパイルエラーになった経緯あり）。
func buildPeopleIndex() -> [String: [String]] {
    var index: [String: [String]] = [:]
    guard let facesSubtype = PHAssetCollectionSubtype(rawValue: 1000) else { return [:] }
    let collections = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: facesSubtype, options: nil)
    collections.enumerateObjects { collection, _, _ in
        guard let name = collection.localizedTitle, !name.isEmpty else { return }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        assets.enumerateObjects { asset, _, _ in
            index[asset.localIdentifier, default: []].append(name)
        }
    }
    return index
}

/// 顔認識（People）インデックスへの公開アクセス。`localIdentifier → 人物名` を
/// バックグラウンドで構築する。自動アルバム（AutoAlbumCore）の人物付与に使う。
public enum BackupPeopleIndex {
    public static func build() async -> [String: [String]] {
        await Task.detached(priority: .utility) { buildPeopleIndex() }.value
    }
}
