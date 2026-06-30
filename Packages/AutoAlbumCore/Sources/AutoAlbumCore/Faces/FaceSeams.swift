import CoreGraphics
import Foundation

/// 1 枚の写真から検出した 1 つの顔（位置と identity 埋め込み）。
/// AutoAlbumCore を Vision/Core ML 非依存に保つための中立値型。
public struct DetectedFaceSignal: Sendable, Equatable {
    /// 顔の矩形（Vision 準拠の正規化座標：原点左下・0…1）。アバター切り抜きに使う。
    public let boundingBox: CGRect
    /// 顔の identity 埋め込み（`ClipMath.encodeHalf` 形式の Float16）。クラスタリングに使う。
    public let embedding: Data
    /// 検出の信頼度（0…1）。低品質の顔を間引く用途。
    public let quality: Float

    public init(boundingBox: CGRect, embedding: Data, quality: Float = 1) {
        self.boundingBox = boundingBox
        self.embedding = embedding
        self.quality = quality
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
