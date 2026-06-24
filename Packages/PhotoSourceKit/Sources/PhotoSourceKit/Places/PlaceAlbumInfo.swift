import Foundation

/// 場所（市区町村）ごとのアルバム相当情報。ローカルと Dropbox の写真を混在で保持する。
/// 値オブジェクト（Foundation のみ）なので `swift test` でグルーピングロジックを検証できる。
public struct PlaceAlbumInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String { placeName }
    /// 市区町村名（無ければ州/県/国）。
    public let placeName: String
    /// この場所のローカル写真（PHAsset.localIdentifier）。
    public let localIDs: [String]
    /// この場所の Dropbox 写真（path）。
    public let cloudPaths: [String]
    public let photoCount: Int
    /// カバー用。ローカルがあれば最新ローカル写真、無ければ最新 Dropbox 写真。
    public let coverLocalID: String?
    public let coverCloudPath: String?
    /// 並び替え用の代表日時（この場所の最新写真）。
    public let representativeDate: Date

    public init(
        placeName: String,
        localIDs: [String],
        cloudPaths: [String],
        photoCount: Int,
        coverLocalID: String?,
        coverCloudPath: String?,
        representativeDate: Date
    ) {
        self.placeName = placeName
        self.localIDs = localIDs
        self.cloudPaths = cloudPaths
        self.photoCount = photoCount
        self.coverLocalID = coverLocalID
        self.coverCloudPath = coverCloudPath
        self.representativeDate = representativeDate
    }
}
