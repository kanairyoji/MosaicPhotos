import Foundation

/// アルバム自動生成（旅行抽出）のパラメータ（設定画面で調整可）。
public struct AlbumGenParams: Sendable, Equatable {
    /// 常用地点の判定に使うグリッド粒度（度）。小さいほど細かく地点を分ける。
    public var gridStepDegrees: Double
    /// 常用地点（自宅・職場・行きつけ）の判定：このセルで撮影した「異なる日数」がこの値以上なら常用扱い。
    public var frequentMinDistinctDays: Int
    /// 旅行判定：写真が全常用地点からこの距離（メートル）以上離れていれば自宅外（away）とみなす。
    public var homeDistanceMeters: Double
    /// 旅行アルバムの最小枚数（多日まとめ後の合計）。これ未満は採用しない。
    public var minTripPhotos: Int
    /// 旅行を1つに束ねる際に許容する「写真の無い空白日数」。これを超えて間が空くと別の旅行に分割する。
    /// 連続する自宅外の日はこの許容内で1旅行にまとまる（多日旅行が日ごとに分割されない）。
    public var maxTripGapDays: Int

    public init(
        gridStepDegrees: Double = 0.02,              // ~2 km
        frequentMinDistinctDays: Int = 5,            // 5 日以上撮った地点は常用
        homeDistanceMeters: Double = 25_000,         // 25 km 以上離れたら旅行
        minTripPhotos: Int = 3,                      // 旅行全体（多日まとめ後）で 3 枚以上
        maxTripGapDays: Int = 2                       // 空白 1 日までは同じ旅行に束ねる
    ) {
        self.gridStepDegrees = gridStepDegrees
        self.frequentMinDistinctDays = frequentMinDistinctDays
        self.homeDistanceMeters = homeDistanceMeters
        self.minTripPhotos = minTripPhotos
        self.maxTripGapDays = maxTripGapDays
    }

    public static let `default` = AlbumGenParams()
}
