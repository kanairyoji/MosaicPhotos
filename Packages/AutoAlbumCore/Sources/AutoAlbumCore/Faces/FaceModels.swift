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

/// ユーザーの顔認識修正の記録（ADR-45）。「この顔はこの人ではない」を**埋め込みで**永続化し、
/// 以後のクラスタリングで同じ誤りを繰り返さないための負例エグゼンプラにする。
/// clusterID はスキャンごとに変わるため、cluster ではなく**埋め込み**をキーにする＝
/// **再スキャン・モデル入れ替えを跨いで**効く（ADR-45 の肝）。`reset()` でも消さない。
@Model
final class FaceCorrection {
    @Attribute(.unique) var id: String
    /// "reassign"（付け替え＝負例）/ "merge"（統合＝将来のための記録）。
    var kind: String
    /// 修正した顔の埋め込み（Float16・正規化前）。入力顔がこれに近ければ「同じ人」とみなす。
    var faceEmbedding: Data
    /// 誤って入っていたクラスタの重心埋め込み（Float16・正規化前）。候補クラスタがこれに近ければ
    /// 「同じ誤りクラスタ」とみなし、合流を拒否する。reassign のみ（merge は nil）。
    var wrongEmbedding: Data?
    var createdAt: Date

    init(id: String, kind: String, faceEmbedding: Data, wrongEmbedding: Data?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.faceEmbedding = faceEmbedding
        self.wrongEmbedding = wrongEmbedding
        self.createdAt = createdAt
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
