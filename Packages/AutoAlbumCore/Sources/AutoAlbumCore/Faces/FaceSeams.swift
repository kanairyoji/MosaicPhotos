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
    /// 顔矩形の最小辺（正規化）。クラウドは低解像度サムネのため大きい顔のみ採る。
    public static func minFaceSide(isCloud: Bool) -> CGFloat { isCloud ? 0.15 : 0.05 }

    /// Vision の faceCaptureQuality に顔向き・目閉じの減衰を適用した「クラスタリング用品質」。
    public static func adjustedQuality(quality: Float, yaw: Float?, roll: Float?,
                                       eyesClosed: Bool?) -> Float {
        var q = quality
        if let yaw, abs(yaw) >= yawLimit { q = min(q, profileCap) }
        if let roll, abs(roll) >= rollLimit { q = min(q, profileCap) }
        if eyesClosed == true { q *= eyesClosedFactor }
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

    public init(boundingBox: CGRect, embedding: Data, quality: Float = 1, hasSmile: Bool? = nil) {
        self.boundingBox = boundingBox
        self.embedding = embedding
        self.quality = quality
        self.hasSmile = hasSmile
    }
}

/// 写真（refKey）から顔を検出して identity 埋め込みを返す seam。
/// 実体はアプリ側（Vision で顔検出＋切り抜き → 同梱 Core ML 顔モデルで埋め込み）。
/// 顔モデル未同梱／未提供なら `isAvailable == false`／空を返し、ピープルは無効になるだけ。
/// `refKeys` は PhotoRef エンコード済みキー（"L-…"/"C-…"）。
public protocol FacePerceptionProvider: Sendable {
    var isAvailable: Bool { get }
    func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]]
}
