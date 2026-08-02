import PerceptionCore
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
    /// ユーザーがこの人物だと**確認**した日時（ADR-46・A2）。確認済みの顔は
    /// (1) クラスタのアンカー（マルチプロトタイプ）になり、(2) 再クラスタリングで
    /// must-link（必ずこの人物へ）として扱われ、(3) レビューで再度尋ねない。
    var confirmedAt: Date?
    /// 笑顔か（CIFaceFeature・face-info-expansion）。代表顔の自動選択で加点。未計測は nil。
    var hasSmile: Bool?
    /// 撮影日（時期グループ分割用・ADR-61）。子供は撮影日≒年齢で成長段階の代理。未取得は nil。
    var captureDate: Date?

    init(faceID: String, refKey: String, bx: Double, by: Double, bw: Double, bh: Double,
         embedding: Data, quality: Double, clusterID: Int, hasSmile: Bool? = nil,
         captureDate: Date? = nil) {
        self.faceID = faceID
        self.refKey = refKey
        self.bx = bx; self.by = by; self.bw = bw; self.bh = bh
        self.embedding = embedding
        self.quality = quality
        self.clusterID = clusterID
        self.hasSmile = hasSmile
        self.captureDate = captureDate
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
    /// 2 階層の人物束ね ID（ADR-61）。**同じ値のクラスタは 1 人物**（子供の成長で分裂した
    /// 時期クラスタを束ねる）。nil = 従来どおり 1 クラスタ=1 人物。名前・代表は束ねの主クラスタが持つ。
    var personGroupID: Int?

    init(clusterID: Int, sum: Data, count: Int, name: String? = nil, coverFaceID: String? = nil,
         personGroupID: Int? = nil) {
        self.clusterID = clusterID
        self.sum = sum
        self.count = count
        self.name = name
        self.coverFaceID = coverFaceID
        self.personGroupID = personGroupID
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
    /// 「同じ誤りクラスタ」とみなし、合流を拒否する。reassign/notSame のみ（merge/confirm は nil）。
    var wrongEmbedding: Data?
    /// 記録時点のペア類似度（しきい値校正＝ADR-46 B1 の材料）。
    /// kind により意味が変わる: reassign=顔×誤り重心（負例）/ merge=重心×重心（正例）/
    /// confirm=顔×所属重心（正例）/ notSame=重心×重心（負例）。
    var similarity: Double?
    var createdAt: Date

    init(id: String, kind: String, faceEmbedding: Data, wrongEmbedding: Data?,
         similarity: Double? = nil, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.faceEmbedding = faceEmbedding
        self.wrongEmbedding = wrongEmbedding
        self.similarity = similarity
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
