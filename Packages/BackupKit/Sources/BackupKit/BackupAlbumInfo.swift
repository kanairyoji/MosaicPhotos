import Foundation

/// バックアップ済みレコードから集計したアルバム情報。
/// PHAssetCollection は使わず BackupAssetRecord.albums をもとに構築する。
public struct BackupAlbumInfo: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let photoCount: Int
    /// サムネイル表示用の PHAsset.localIdentifier（最新写真）。
    public let coverLocalIdentifier: String?
    /// このアルバムに属する PHAsset.localIdentifier の一覧。
    public let localIdentifiers: [String]
}
