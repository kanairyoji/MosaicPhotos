import Foundation

/// アルバム生成の入力となる「付加情報済みの1枚」。ローカル/クラウドを統一する Sendable 値型。
/// `id` はエンコード済みの `PhotoRef`（"L-…"/"C-…"）。戦略は id を不透明な識別子として扱う。
public struct EnrichedPhoto: Sendable, Equatable {
    public let id: String
    public let captureDate: Date?
    public let latitude: Double?
    public let longitude: Double?
    /// 逆ジオコード済みの地名（市区町村など）。
    public let placeName: String?
    /// 国名（海外旅行のタイトル判定用）。
    public let country: String?
    /// 同一写真を束ねる鍵（バックアップ済みローカルの path / クラウド自身の path）。重複排除用。
    public let linkKey: String?
    /// スクリーンショットか（旅行・カバーから除外）。
    public let isScreenshot: Bool
    /// お気に入りか（カバー選定の優先度）。
    public let isFavorite: Bool
    /// 縦横比（幅/高さ）。横長カバーの優先に使う。不明は nil。
    public let aspect: Double?
    /// 写っている人物名（People アルバム由来）。
    public let people: [String]
    /// CLIP 画像埋め込み（FP32 LE の `Data`）。意味検索用。未計算は nil。
    public let clipVector: Data?

    public init(id: String, captureDate: Date?, latitude: Double?, longitude: Double?,
                placeName: String?, country: String? = nil, linkKey: String? = nil,
                isScreenshot: Bool = false, isFavorite: Bool = false, aspect: Double? = nil,
                people: [String] = [], clipVector: Data? = nil) {
        self.id = id
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.country = country
        self.linkKey = linkKey
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.aspect = aspect
        self.people = people
        self.clipVector = clipVector
    }

    public var ref: PhotoRef? { PhotoRef.decode(id) }
    public var isLocal: Bool { ref?.isLocal ?? false }
    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    public func withLinkKey(_ key: String?) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: captureDate, latitude: latitude, longitude: longitude,
                      placeName: placeName, country: country, linkKey: key, isScreenshot: isScreenshot,
                      isFavorite: isFavorite, aspect: aspect, people: people,
                      clipVector: clipVector)
    }

    public func withClipVector(_ vector: Data?) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: captureDate, latitude: latitude, longitude: longitude,
                      placeName: placeName, country: country, linkKey: linkKey, isScreenshot: isScreenshot,
                      isFavorite: isFavorite, aspect: aspect, people: people,
                      clipVector: vector)
    }

    public func withCoordinate(latitude: Double?, longitude: Double?) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: captureDate, latitude: latitude, longitude: longitude,
                      placeName: placeName, country: country, linkKey: linkKey, isScreenshot: isScreenshot,
                      isFavorite: isFavorite, aspect: aspect, people: people,
                      clipVector: clipVector)
    }
}
