import PerceptionCore
import Foundation
import SwiftData

/// 1 写真分の CLIP 画像埋め込み（半精度 Float16 でパック・約1KB）。
///
/// `PhotoEnrichment` 本体から **意図的に分離** したテーブル。メタデータ取得（生成・重複排除・戦略・
/// フォルダ）は `PhotoEnrichment` を全件 fetch するが、その際に巨大な埋め込み blob を一切ロード
/// しないようにするのが目的（inline 格納だと SwiftData は fetch 時に Data も丸ごと展開し、
/// 67k×2KB ≈ 138MB を確保 → 実機で写真枚数に比例した起動クラッシュの原因になっていた）。
///
/// 検索（`AIAlbumSearcher`）と表示タグ（`CLIPDisplayLabeler`）だけがこのテーブルを
/// **ページング**して読む。`refKey` は `PhotoEnrichment.refKey` と 1:1。
@Model
final class PhotoEmbedding {
    @Attribute(.unique) var refKey: String
    /// Float16 little-endian でパックした 512 次元ベクトル。`ClipMath.encodeHalf` / `decodeHalf` で変換。
    var vector: Data
    /// このベクトルを作った CLIP モデルの ID（`ModelGeneration.clip`・ADR-186）。
    /// ⚠️ **optional で後から足した列**（軽量マイグレーション＝既存データを保つ）。nil は列の導入前に
    /// 作られた行で `ModelGeneration.legacyClip` とみなす。モデル更新時は行を少しずつ上書きしていく
    /// （DB を丸ごと作り直さない）。空間が違うベクトルは検索で混ぜない（`isSearchableClip`）。
    var modelID: String?

    init(refKey: String, vector: Data, modelID: String? = ModelGeneration.clip) {
        self.refKey = refKey
        self.vector = vector
        self.modelID = modelID
    }
}
