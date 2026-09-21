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
    /// この顔が**クラスタ重心（sum/count）に寄与しているか**。
    ///
    /// ⚠️ 品質フロア未満の顔は「membership だけ」割り当てる（重心を汚さない・ADR-66）。
    /// 付け替え時にその顔まで `removing` で減算すると、寄与していない分を引くことになり
    /// **重心が壊れる**。count==1 のクラスタでは「最後の 1 顔」と誤認してクラスタごと消え、
    /// 残った顔が存在しないクラスタ ID を指す（レビュー指摘）。
    /// nil＝この列より前に作られた行（品質フロアで推定する）。
    ///
    /// ⚠️⚠️ **これは「事実の記録」であって「方針」ではない**（ADR-210）。書いてよいのは
    /// 実際に `sum` へ足した（または足さなかった）当人だけで、後から品質で推し量してはいけない。
    /// 以前は再クラスタの書き戻しが「留めた顔はすべて寄与した」と記録しており、
    /// 実際の `sum` は品質フロア以上の顔だけで作られていた——実ライブラリでは顔の約半数が
    /// フロア未満なので、30 枚の人物で `count == 4` なのに 30 行が「寄与した」と言う状態になった。
    /// その人物から数枚外すと `count` が尽き、**人物が丸ごと消える**（`FaceCentroidAudit` が見張る）。
    var contributesToCentroid: Bool?

    /// **撤回**（ADR-212）: 服装（胴体）の CLIP 埋め込みを入れていた列。PIPA の計測で
    /// 服装による連結に効果が無いと分かり、書き手を撤去した。台帳（FacesV1）は列を消さない
    /// 方針（ADR-186）なので列だけ残し、再クラスタが残った値を空にする。常に nil。
    var torsoEmbedding: Data?

    /// **何を根拠にこの人物へ入ったか**（`FaceLinkSource` の rawValue・ADR-212）。
    ///
    /// ⚠️ 根拠を残さないと、後から効果を測れない。「どの根拠で入った顔を、ユーザーが
    /// 何割外したか」は実機でしか分からない（ADR-162 と同じ）。
    var linkSource: String?

    init(faceID: String, refKey: String, bx: Double, by: Double, bw: Double, bh: Double,
         embedding: Data, quality: Double, clusterID: Int, hasSmile: Bool? = nil,
         captureDate: Date? = nil, contributesToCentroid: Bool? = nil,
         linkSource: String? = nil) {
        self.faceID = faceID
        self.refKey = refKey
        self.bx = bx; self.by = by; self.bw = bw; self.bh = bh
        self.embedding = embedding
        self.quality = quality
        self.clusterID = clusterID
        self.hasSmile = hasSmile
        self.captureDate = captureDate
        self.contributesToCentroid = contributesToCentroid
        self.torsoEmbedding = nil
        self.linkSource = linkSource
    }
}

/// 顔が人物へ入った**根拠**（ADR-212）。効果を測るために行へ残す。
enum FaceLinkSource: String, Sendable, CaseIterable {
    /// 顔の埋め込みで本割り当て（重心を作った）。
    case face
    /// 顔の埋め込みで第2パス（membership のみ・ADR-66）。
    case secondPass
    /// 断片の自動吸収（ADR-154）。
    case absorb
    /// ユーザーの表明（確認・付け替え・統合）。
    case user
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

    /// **メンバーの散らばり**（`FaceClusterHealth.spread`・ADR-210）。重心からの距離
    /// （1 − コサイン）の品質重み付き中央値で、夜間の再クラスタが測り直して入れる。
    /// nil = まだ測っていない（この列より前の行・断片）。
    ///
    /// ⚠️ 「純度が低い」を直接は測れない（正解を知らないので）。散らばりは**その代理**で、
    /// 過半のメンバーが重心から遠い＝重心がもう誰の顔でもない、という状態を捕まえる。
    var spread: Double?

    init(clusterID: Int, sum: Data, count: Int, name: String? = nil, coverFaceID: String? = nil,
         personGroupID: Int? = nil, spread: Double? = nil) {
        self.clusterID = clusterID
        self.sum = sum
        self.count = count
        self.name = name
        self.coverFaceID = coverFaceID
        self.personGroupID = personGroupID
        self.spread = spread
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
    /// **回答の確度**（ADR-68 追補6）。同じ「はい」でも、判断材料の量で信頼度は変わる:
    /// - 1.0 **1 対 1 の確認**（2 枚を並べて「同じ人ですか？」）＝ 材料が揃った判断。
    /// - 1.0 **手動の付け替え/統合**＝ ユーザーが対象を明示的に選んでいる。
    /// - 0.4 **まとめて確認**＝ 小さなアバターを一覧から選ぶので取り違えが起こりやすく、
    ///   1 セッションで数百件入るため、等重みだと校正がこれ一色に染まる。
    /// 既存行（列追加前）は nil ＝ 1.0 として扱う。
    var confidence: Double?
    /// **どのモデルスケールで記録されたか**（FaceTuning.name・ADR-70 追補）。
    /// 埋め込み・類似度はモデルの空間に張り付いており、**別モデルの行は再利用できない**
    /// （facenet の類似度 0.5-0.7 が AuraFace の校正を上限まで押し上げた実障害）。
    /// 既存行（列追加前）は nil ＝ "facenet"（v4 世代）として扱う。
    var profile: String?
    /// **この顔が何を根拠に入っていたか**（`FaceLinkSource` の rawValue・ADR-212）。
    ///
    /// ⚠️ 修正のときに**その場で**控える。あとから顔の行を見に行っても、もう付け替え済みで
    /// 根拠は失われている。これがあると「第2パスで入った顔を、ユーザーが何割外したか」が出せる。
    var linkSource: String?
    var createdAt: Date

    init(id: String, kind: String, faceEmbedding: Data, wrongEmbedding: Data?,
         similarity: Double? = nil, confidence: Double? = nil, profile: String? = nil,
         linkSource: String? = nil, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.faceEmbedding = faceEmbedding
        self.wrongEmbedding = wrongEmbedding
        self.similarity = similarity
        self.confidence = confidence
        self.profile = profile
        self.linkSource = linkSource
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
