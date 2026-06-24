import Foundation

/// ローカル写真ライブラリのアルバム情報。
/// PHAssetCollection をそのまま持ち歩かず、スキャン時にキャッシュした値だけを保持する。
public struct LocalAlbumInfo: Identifiable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let photoCount: Int
    /// サムネイル用の PHAsset.localIdentifier（アルバム最新写真）。
    public let coverLocalIdentifier: String?
    /// このアルバムに含まれる PHAsset.localIdentifier 一覧。
    public let localIdentifiers: [String]
}
