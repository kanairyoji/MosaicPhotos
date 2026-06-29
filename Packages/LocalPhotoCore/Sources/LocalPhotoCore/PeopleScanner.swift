import Foundation
import Observation
import Photos
import PhotoSourceKit

// MARK: - Scanner

/// ローカル写真ライブラリの「ピープル（人物＝顔アルバム）」をスキャンしてキャッシュする。
///
/// - `LocalAlbumScanner`（端末アルバム）と同じ流儀。表示はキャッシュ済みの `PersonAlbumInfo` を使う。
/// - 人物（顔）アルバムは `PHAssetCollectionSubtype(rawValue: 1000)`（albumFaces・名前付き定数なし）で取得する。
/// - キャッシュは Application Support/PeopleCache.json に保存する。
@MainActor
@Observable
public final class PeopleScanner {

    public private(set) var people: [PersonAlbumInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isScanning = false
    public private(set) var lastScanned: Date?

    private static let cacheTTL: TimeInterval = 60 * 60 * 24  // 24 時間

    public init() {}

    // MARK: - Public API

    /// キャッシュがあればロード、なければスキャン。TTL 超過時はロード後に背景再スキャン。
    public func loadOrScan() async {
        if let cached = loadCache() {
            people      = cached.people
            lastScanned = cached.scannedAt
            isLoaded    = true
            if Date().timeIntervalSince(cached.scannedAt) > Self.cacheTTL {
                Task { await scan() }
            }
        } else {
            await scan()
        }
    }

    /// 写真ライブラリの人物（顔）アルバムをスキャンしてキャッシュに保存する。
    /// 権限がない場合はスキップして isLoaded = true にする。
    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            isLoaded = true
            return
        }

        // ⚠️ buildPeopleAlbums はトップレベル関数（Task.detached 内で @MainActor 型を捕捉しないため）。
        let scanned = await Task.detached { buildPeopleAlbums() }.value
        let now = Date()
        people      = scanned
        lastScanned = now
        isLoaded    = true
        store.save(PeopleCache(scannedAt: now, people: scanned))
    }

    // MARK: - Cache persistence

    private let store = JSONFileStore<PeopleCache>(
        filename: "PeopleCache.json", in: .applicationSupportDirectory)

    private func loadCache() -> PeopleCache? { store.load() }
}

// MARK: - Cache model

private struct PeopleCache: Codable {
    let scannedAt: Date
    let people: [PersonAlbumInfo]
}

// MARK: - Top-level scanner (Task.detached 対応)

// ⚠️ トップレベル関数として定義すること（@MainActor 型のインスタンスメソッドにしない）。
private func buildPeopleAlbums() -> [PersonAlbumInfo] {
    // 顔アルバムのサブタイプ（iOS SDK に名前付き定数が無いため rawValue 1000 = albumFaces）。
    guard let facesSubtype = PHAssetCollectionSubtype(rawValue: 1000) else { return [] }

    let imageOpts = PHFetchOptions()
    imageOpts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

    var result: [PersonAlbumInfo] = []
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: facesSubtype, options: nil)
    collections.enumerateObjects { collection, _, _ in
        // 名前が付いている人物だけを対象にする（未命名の顔クラスタは localizedTitle が空/nil）。
        guard let name = collection.localizedTitle, !name.isEmpty else { return }
        let assets = PHAsset.fetchAssets(in: collection, options: imageOpts)
        guard assets.count > 0 else { return }

        var identifiers: [String] = []
        identifiers.reserveCapacity(assets.count)
        assets.enumerateObjects { a, _, _ in identifiers.append(a.localIdentifier) }

        result.append(PersonAlbumInfo(
            name: name,
            photoCount: assets.count,
            coverLocalIdentifier: assets.lastObject?.localIdentifier,
            localIdentifiers: identifiers
        ))
    }

    // 写真の多い人物を先頭に（Apple 写真の People と同様に主要な人を上位へ）。
    return result.sorted {
        $0.photoCount != $1.photoCount
            ? $0.photoCount > $1.photoCount
            : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
