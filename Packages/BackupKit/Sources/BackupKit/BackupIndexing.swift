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

// ⚠️ buildAlbumIndex はトップレベル関数である必要がある。
// インスタンスメソッドとして定義すると Task.detached クロージャ内でコンパイラが
// @MainActor 型の self を捕捉しようとしてコンパイルエラーになる（過去に発生）。

/// アルバム名 → PHAssetCollection.localIdentifier（カタログの改名対策・ADR-39）。
/// buildAlbumIndex と同じ理由でトップレベル関数（Task.detached から呼ぶ）。
func buildAlbumIDIndex() -> [String: String] {
    var ids: [String: String] = [:]
    let collections = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .albumRegular, options: nil)
    collections.enumerateObjects { collection, _, _ in
        guard let name = collection.localizedTitle, !name.isEmpty else { return }
        ids[name] = collection.localIdentifier
    }
    return ids
}

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
