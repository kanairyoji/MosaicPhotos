import Foundation

/// 戦略が生成するアルバムの下書き（永続化前の Sendable 値）。
/// メンバー/カバーはエンコード済み `PhotoRef`（"L-…"/"C-…"）で持ち、ローカル/クラウド混在に対応する。
public struct GeneratedAlbumDraft: Sendable, Equatable {
    public let strategyID: String
    /// 代表地名（最頻）。
    public let placeName: String?
    /// 訪問地（多い順・複数都市の旅行用）。
    public let places: [String]
    /// 国名（海外旅行のとき）。
    public let country: String?
    public let startDate: Date
    public let endDate: Date
    public let memberRefs: [String]
    public let coverRef: String?
    /// 写っている人物（多い順）。
    public let people: [String]
    /// 代表座標（詳細ヘッダーの地図用）。
    public let latitude: Double?
    public let longitude: Double?

    public init(strategyID: String, placeName: String?, places: [String] = [], country: String? = nil,
                startDate: Date, endDate: Date, memberRefs: [String], coverRef: String?,
                people: [String] = [], latitude: Double? = nil, longitude: Double? = nil) {
        self.strategyID = strategyID
        self.placeName = placeName
        self.places = places
        self.country = country
        self.startDate = startDate
        self.endDate = endDate
        self.memberRefs = memberRefs
        self.coverRef = coverRef
        self.people = people
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 並び順の基準。最新（endDate）が大きいほど上位。
    public var representativeDate: Date { endDate }
    public var photoCount: Int { memberRefs.count }
}

/// アルバム自動生成の戦略インターフェイス。新しい自動アルバム種別はこの適合型を増やすだけで足り、
/// エンジン本体は変更不要（機能肥大化の抑制）。
public protocol AlbumStrategy: Sendable {
    /// 戦略を一意に識別する文字列（永続化・冪等判定に使用）。
    var id: String { get }
    /// 付加情報済み写真からアルバム下書きを生成する。純ロジック（テスト対象）。
    func makeAlbums(from photos: [EnrichedPhoto], params: AlbumGenParams) -> [GeneratedAlbumDraft]
}
