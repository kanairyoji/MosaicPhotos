import Foundation

/// 自動アルバム機能の永続設定キー。
public enum AutoAlbumSettingsKeys {
    /// バックグラウンド自動生成の ON/OFF。
    public static let backgroundEnabled = "autoAlbumBackgroundEnabled"
    /// 既存 iPhone アルバムの写真を除外するか（dedup）。**既定 false＝重複を気にせず生成**。
    public static let excludeAlbumed = "autoAlbumExcludeAlbumed"
    /// Dropbox 写真を自動アルバムに含めるか。**既定 true**（未接続時は実質ローカルのみ）。
    public static let includeCloud = "autoAlbumIncludeCloud"
    /// 最後に生成したときのロジックのバージョン。現行版と異なれば起動時に1回だけ自動再生成する
    /// （命名・グルーピングの改善を既存アルバムへ反映するため）。
    public static let generationVersion = "autoAlbumGenerationVersion"
    /// 最後にタグ付け（Vision/CLIP 知覚）した時のロジックのバージョン。現行版と異なれば起動時に
    /// 1回だけ全ローカル写真の sceneTagged をリセットし、改善した知覚ロジックで付け直す。
    public static let perceptionVersion = "autoAlbumPerceptionVersion"
    /// 最後にキャプション付けした VLM モデルのバージョン。現行版と異なれば起動時に 1 回だけ
    /// 既存キャプションをクリアし、新モデル（Florence-2 等）で付け直す（`captionPending` は
    /// `caption==nil` のみ対象なので、モデル差し替え時はクリアしないと旧キャプションが残る）。
    public static let captionModelVersion = "autoAlbumCaptionModelVersion"
    /// バックグラウンド埋め込みの重さ段階（`BackgroundProcessing.presets` のインデックス）。
    public static let backgroundProcessingLevel = "autoAlbumBackgroundLevel"
    /// フォルダ名アルバム（Dropbox パスから推測）を有効にするか。**既定 false**。
    public static let pathAlbumsEnabled = "autoAlbumPathEnabled"
    /// フォルダ名アルバムの抽出ルール（`[PathAlbumRule]` の JSON 文字列）。
    public static let pathAlbumRules = "autoAlbumPathRules"

    // MARK: - 旅行抽出パラメータ
    /// 常用地点セルの粒度（度 ×1000 で保存。例 20 = 0.02°）。既定 20。
    public static let gridStepMilliDegrees = "autoAlbumGridStepMilliDeg"
    /// 常用地点とみなす「異なる日数」。既定 5。
    public static let frequentMinDistinctDays = "autoAlbumFrequentMinDays"
    /// 旅行とみなす「常用地点からの距離」（km）。既定 25。
    public static let homeDistanceKm = "autoAlbumHomeDistanceKm"
    /// 旅行アルバムの最小枚数（多日まとめ後の合計）。既定 3。
    public static let minTripPhotos = "autoAlbumMinTripPhotos"
    /// 旅行を束ねる際に許容する空白日数。既定 2（空白1日まで同一旅行）。
    public static let maxTripGapDays = "autoAlbumMaxTripGapDays"
}

public extension AlbumGenParams {
    /// 設定（UserDefaults）から現在のパラメータを読む。未設定キーは既定値。
    static var current: AlbumGenParams {
        let ud = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            ud.object(forKey: key) as? Int ?? fallback
        }
        return AlbumGenParams(
            gridStepDegrees: Double(int(AutoAlbumSettingsKeys.gridStepMilliDegrees, 20)) / 1000.0,
            frequentMinDistinctDays: int(AutoAlbumSettingsKeys.frequentMinDistinctDays, 5),
            homeDistanceMeters: Double(int(AutoAlbumSettingsKeys.homeDistanceKm, 25) * 1000),
            minTripPhotos: int(AutoAlbumSettingsKeys.minTripPhotos, 3),
            maxTripGapDays: int(AutoAlbumSettingsKeys.maxTripGapDays, 2))
    }
}
