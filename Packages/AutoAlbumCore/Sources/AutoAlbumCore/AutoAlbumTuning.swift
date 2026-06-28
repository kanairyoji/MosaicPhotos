import Foundation

/// 自動アルバム/埋め込みのメモリ系チューニング値を**表示用に公開**するファサード。
/// 実体（`AutoAlbumStore`）は internal なので、Developer 診断から参照できるようここへ集約する。
public enum AutoAlbumTuning {
    /// 意味検索で埋め込み（PhotoEmbedding）を読むページサイズ。1ページの常駐 ≈ pageSize×2KB(fp32復元)。
    public static let semanticSearchPageSize = 4000
    /// 大量 upsert を使い捨て ModelContext で区切る件数（常駐を有界化）。
    public static let upsertWriteChunk = 500
}
