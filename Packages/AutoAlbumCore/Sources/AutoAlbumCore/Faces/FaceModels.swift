import Foundation
import SwiftData

/// 1 枚の写真から検出した 1 つの顔。埋め込み（Float16）とクラスタ割当を持つ。
/// ピープル（顔クラスタ）の永続層。CLIP の `PhotoEnrichment`/`PhotoEmbedding` とは**別コンテナ**
/// （`FaceStore`）に置くため、顔機能の追加で既存の CLIP データを破棄せずに済む。
@Model
final class DetectedFace {
    /// "<refKey>#<index>"（同一写真内の複数顔を区別）。
    @Attribute(.unique) var faceID: String
    var refKey: String
    /// 顔矩形（Vision 正規化座標：原点左下・0…1）。アバター切り抜き用。
    var bx: Double
    var by: Double
    var bw: Double
    var bh: Double
    /// identity 埋め込み（Float16・`ClipMath.encodeHalf`）。
    var embedding: Data
    var quality: Double
    /// 割り当てられたクラスタ ID（未割当は -1）。
    var clusterID: Int

    init(faceID: String, refKey: String, bx: Double, by: Double, bw: Double, bh: Double,
         embedding: Data, quality: Double, clusterID: Int) {
        self.faceID = faceID
        self.refKey = refKey
        self.bx = bx; self.by = by; self.bw = bw; self.bh = bh
        self.embedding = embedding
        self.quality = quality
        self.clusterID = clusterID
    }
}

/// 顔クラスタ（＝1 人物）。重心更新用の生合計と件数、任意の名前・代表顔を持つ。
/// 重心 = normalize(decode(sum))。逐次クラスタリングで sum/count を加算していく。
@Model
final class PersonCluster {
    @Attribute(.unique) var clusterID: Int
    /// 正規化前の生合計（Float16）。重心はこれを正規化して得る。
    var sum: Data
    var count: Int
    var name: String?
    var coverFaceID: String?

    init(clusterID: Int, sum: Data, count: Int, name: String? = nil, coverFaceID: String? = nil) {
        self.clusterID = clusterID
        self.sum = sum
        self.count = count
        self.name = name
        self.coverFaceID = coverFaceID
    }
}

/// 顔スキャン済みマーカー（顔が 0 件の写真も「処理済み」と分かるように記録する）。
@Model
final class ScannedPhoto {
    @Attribute(.unique) var refKey: String
    var faceCount: Int

    init(refKey: String, faceCount: Int) {
        self.refKey = refKey
        self.faceCount = faceCount
    }
}
