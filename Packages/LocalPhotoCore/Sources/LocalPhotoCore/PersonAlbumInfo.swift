import Foundation

/// ローカル写真ライブラリの「ピープル（人物）」1 件分の情報。
/// PHAssetCollection（顔アルバム）をそのまま持ち歩かず、スキャン時にキャッシュした値だけを保持する。
public struct PersonAlbumInfo: Identifiable, Codable, Sendable {
    public var id: String { name }
    /// 人物名（写真アプリで名前を付けた人）。
    public let name: String
    public let photoCount: Int
    /// サムネイル（円形アバター）用の PHAsset.localIdentifier。
    public let coverLocalIdentifier: String?
    /// この人物の写真の PHAsset.localIdentifier 一覧。
    public let localIdentifiers: [String]

    public init(name: String, photoCount: Int, coverLocalIdentifier: String?, localIdentifiers: [String]) {
        self.name = name
        self.photoCount = photoCount
        self.coverLocalIdentifier = coverLocalIdentifier
        self.localIdentifiers = localIdentifiers
    }
}
