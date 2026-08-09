import PerceptionCore
import CoreGraphics
import Foundation

/// 1 枚の写真から検出した 1 つの顔（位置と identity 埋め込み）。
/// AutoAlbumCore を Vision/Core ML 非依存に保つための中立値型。
/// 顔品質の調整規則（純ロジック・face-info-expansion 優先度 1/3/4）。
/// 横顔・大きな傾き・目閉じは埋め込みの信頼性が下がるため、クラスタリングに渡す品質を
/// ここで一元的に減衰する（フロア未満＝未割当となり重心を汚さない）。
public enum FaceQualityGate {
    /// 横顔とみなす yaw（左右向き）のしきい値（ラジアン・±30°）。
    public static let yawLimit: Float = 0.5236
    /// 大きな傾きとみなす roll のしきい値（ラジアン・±45°）。
    public static let rollLimit: Float = 0.7854
    /// 横顔/大傾きの品質キャップ（qualityFloor 未満＝クラスタへ入れない）。
    public static let profileCap: Float = 0.2
    /// 目閉じの品質係数。
    public static let eyesClosedFactor: Float = 0.6
    /// 顔矩形の最小辺（正規化）。
    /// ⚠️ クラウドの 0.15 は「サムネが 256px しかない」ことの代理指標だった（ADR-90）。
    /// 解析用に 1024px を取るようになったので、比率ゲートはローカルと同じでよい
    /// （絶対ピクセル下限 `minFacePixels` が本来の品質条件を担う）。
    public static func minFaceSide(isCloud: Bool) -> CGFloat { 0.05 }
    /// 顔検出の最低信頼度（VNFaceObservation.confidence）。これ未満は「顔でない」誤検出と
    /// みなして埋め込み自体を行わない（模様・ぼけた物体などの偽陽性対策）。
    public static let minDetectionConfidence: Float = 0.8
    /// クロップ再検証: 顔中心に切り抜いた画像内でもう一度顔検出したとき、検出顔がクロップ幅の
    /// この割合以上を占めること（占めなければ「顔でない」と判断して棄却）。
    public static let cropVerifyMinSide: CGFloat = 0.25

    /// 顔矩形の最小辺（**絶対ピクセル**）。比率を満たしても実ピクセルが小さすぎる顔は
    /// 埋め込みが機能しないため除外する（比率ゲートと二段構え）。
    ///
    /// **80px の根拠（ADR-90・実測 diag-35）**: 顔モデル（AuraFace）の入力は 112×112 なので、
    /// 80px なら拡大は 1.4 倍に収まり、埋め込み品質を保てる。旧値 48px は 2.3 倍の拡大になり、
    /// 「通ったけれど品質が低い」顔を量産していた（クラウドの歩留まりが低い一因）。
    /// 実写真 571 枚の歩留まり実測（1024px 取得時）:
    ///   下限 48px → 49.3% ／ **80px → 29.7%** ／ 112px → 18.0%
    /// 拾える量（29.7%＝現行 3.8% の 8 倍）と品質のつり合いで 80px を採る。
    public static let minFacePixels: CGFloat = 80

    // ぼけゲート（顔クロップを 64px 正方に縮小した輝度のラプラシアン分散・0〜255 スケール）。
    /// これ未満は強いぼけ → 品質をフロア未満へキャップ（クラスタに入れない）。
    public static let blurHardFloor: Float = 25
    /// これ未満は軽いぼけ → 品質を減衰。
    public static let blurSoftFloor: Float = 60
    public static let blurSoftFactor: Float = 0.7

    // 露出ゲート（同じ縮小輝度の平均・0〜255）。
    /// 極端な暗部/白飛び → 品質をフロア未満へキャップ。
    public static let lumaHardDark: Float = 20
    public static let lumaHardBright: Float = 235
    /// 暗め/明るめ → 品質を減衰。
    public static let lumaSoftDark: Float = 40
    public static let lumaSoftBright: Float = 215
    public static let exposureFactor: Float = 0.6

    /// Vision の faceCaptureQuality に顔向き・目閉じ・ぼけ・露出の減衰を適用した
    /// 「クラスタリング用品質」。未計測（nil）の指標は減衰しない（フォールバック検出でも動く）。
    public static func adjustedQuality(quality: Float, yaw: Float?, roll: Float?,
                                       eyesClosed: Bool?,
                                       blurVariance: Float? = nil,
                                       meanLuma: Float? = nil) -> Float {
        var q = quality
        if let yaw, abs(yaw) >= yawLimit { q = min(q, profileCap) }
        if let roll, abs(roll) >= rollLimit { q = min(q, profileCap) }
        if eyesClosed == true { q *= eyesClosedFactor }
        if let blurVariance {
            if blurVariance < blurHardFloor { q = min(q, profileCap) }
            else if blurVariance < blurSoftFloor { q *= blurSoftFactor }
        }
        if let meanLuma {
            if meanLuma < lumaHardDark || meanLuma > lumaHardBright { q = min(q, profileCap) }
            else if meanLuma < lumaSoftDark || meanLuma > lumaSoftBright { q *= exposureFactor }
        }
        return q
    }
}

public struct DetectedFaceSignal: Sendable, Equatable {
    /// 顔の矩形（Vision 準拠の正規化座標：原点左下・0…1）。アバター切り抜きに使う。
    public let boundingBox: CGRect
    /// 顔の identity 埋め込み（`ClipMath.encodeHalf` 形式の Float16）。クラスタリングに使う。
    public let embedding: Data
    /// 検出の信頼度（0…1）。低品質の顔を間引く用途。
    public let quality: Float
    /// 笑顔か（CIFaceFeature.hasSmile・face-info-expansion）。未計測は nil。
    public let hasSmile: Bool?
    /// 撮影日（時期グループ分割用・ADR-61）。アプリが refKey から解決して載せる。未取得は nil。
    public let captureDate: Date?

    public init(boundingBox: CGRect, embedding: Data, quality: Float = 1, hasSmile: Bool? = nil,
                captureDate: Date? = nil) {
        self.boundingBox = boundingBox
        self.embedding = embedding
        self.quality = quality
        self.hasSmile = hasSmile
        self.captureDate = captureDate
    }
}

/// 写真（refKey）から顔を検出して identity 埋め込みを返す seam。
/// 実体はアプリ側（Vision で顔検出＋切り抜き → 同梱 Core ML 顔モデルで埋め込み）。
/// 顔モデル未同梱／未提供なら `isAvailable == false`／空を返し、ピープルは無効になるだけ。
/// `refKeys` は PhotoRef エンコード済みキー（"L-…"/"C-…"）。
public protocol FacePerceptionProvider: Sendable {
    var isAvailable: Bool { get }
    /// 埋め込みパイプラインの版（ADR-70）。**同梱モデル側（face_config.json）が宣言**する。
    /// 版が上がると全再スキャン（埋め込みの作り方が変わると新旧のコサイン類似度が壊れるため）。
    /// 定数でなく設定駆動にするのは、**モデルを再生成せずにアプリだけ更新した**場合に
    /// 誤って旧モデルのまま全再スキャンが走るのを防ぐため（版はモデルと一緒に届く）。
    var pipelineVersion: Int { get }
    /// 類似度スケール依存の定数一式（ADR-70）。同梱モデルの宣言（face_config.json の tuning）。
    var tuning: FaceTuning { get }
    func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]]
    /// これから処理する refKey 群の素材を**先に取りに行く**ヒント（ADR-83）。
    /// クラウド写真はサムネの往復（1 枚 600〜800ms）が推論と直列になり支配的だったため、
    /// バッチ単位でまとめて要求してダウンロードを並列化・先行させる。
    /// **即座に返る**こと（実際の取得は非同期）。ローカルのみの実装は何もしなくてよい。
    func warmUp(refKeys: [String])
}

public extension FacePerceptionProvider {
    /// 既定は v4（facenet 世代・ADR-54 まで）。
    var pipelineVersion: Int { 4 }
    /// 既定は facenet プロファイル（後方互換）。
    var tuning: FaceTuning { .facenet }
    /// 既定は無処理（先読みの必要がないローカル専用実装向け）。
    func warmUp(refKeys: [String]) {}
}
