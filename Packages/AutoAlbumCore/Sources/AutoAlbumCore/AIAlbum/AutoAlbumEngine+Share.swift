import Foundation

/// 写真 1 枚分の解析輸出値（家族共有サイドカー用・ADR-112）。
/// タグ台帳（TagsV1）と CLIP 埋め込み（AutoAlbumV10）から組み立てる Sendable 値。
public struct PhotoAnalysisExport: Sendable {
    public let tags: [String]
    public let ocrText: String?
    public let humanCount: Int?
    public let aesthetic: Double?
    /// CLIP 埋め込み（Float16 512 次元パック）。未解析は nil。
    public let clipHalf: Data?

    public init(tags: [String], ocrText: String?, humanCount: Int?,
                aesthetic: Double?, clipHalf: Data?) {
        self.tags = tags
        self.ocrText = ocrText
        self.humanCount = humanCount
        self.aesthetic = aesthetic
        self.clipHalf = clipHalf
    }
}

/// 家族共有（ADR-112）の解析輸出入ファサード。
/// 送信側: 共有セットのサイドカーへ載せる解析を取り出す。
/// 受信側: 家族のサイドカー由来の解析を取り込む（既存レコードは上書きしない＝自前解析優先）。
extension AutoAlbumEngine {

    /// サイドカーのセクション版（送信側が記載・受信側は一致時のみ取り込む）。
    public static var shareTagVersion: Int { TagStore.currentVersion }
    public static var sharePerceptionVersion: Int { perceptionVersion }

    /// refKey 群の解析輸出値。タグ・OCR・人数・美的スコア・CLIP 埋め込みを 1 回で引く。
    public func analysisExport(forRefKeys keys: [String]) async -> [String: PhotoAnalysisExport] {
        guard !keys.isEmpty else { return [:] }
        let tags = await tagStore.tags(forRefKeys: keys)
        let ocr = await tagStore.ocrTexts(forRefKeys: keys)
        let humans = await tagStore.humanCounts(forRefKeys: keys)
        let aesthetics = await tagStore.aesthetics(forRefKeys: keys)
        let embeddings = await store.embeddingsHalf(forRefKeys: keys)

        var out: [String: PhotoAnalysisExport] = [:]
        for key in keys {
            let export = PhotoAnalysisExport(
                tags: tags[key] ?? [], ocrText: ocr[key], humanCount: humans[key],
                aesthetic: aesthetics[key], clipHalf: embeddings[key])
            // 何も解析が無い写真は載せない（サイドカーの無駄を省く）。
            if !export.tags.isEmpty || export.ocrText != nil || export.humanCount != nil
                || export.aesthetic != nil || export.clipHalf != nil {
                out[key] = export
            }
        }
        return out
    }

    /// 取り込み: タグ台帳と埋め込みへ登録する。**既存レコードのある refKey はスキップ**する
    /// （受信側が自前解析済み・または過去に取り込み済み）。登録件数を返す。
    public func importSharedAnalysis(
        tags tagBatch: [(refKey: String, info: PhotoSenseInfo)],
        embeddings embeddingBatch: [(refKey: String, vectorHalf: Data)]
    ) async -> (tags: Int, embeddings: Int) {
        var tagsAdded = 0
        if !tagBatch.isEmpty {
            let existing = await tagStore.tags(forRefKeys: tagBatch.map(\.refKey))
            let fresh = tagBatch.filter { existing[$0.refKey] == nil }
            if !fresh.isEmpty {
                await tagStore.recordTags(fresh)
                tagsAdded = fresh.count
            }
        }
        var embeddingsAdded = 0
        if !embeddingBatch.isEmpty {
            embeddingsAdded = await store.upsertImportedEmbeddings(embeddingBatch)
        }
        if tagsAdded > 0 || embeddingsAdded > 0 {
            Self.log.info("share import: +\(tagsAdded) tags, +\(embeddingsAdded) embeddings")
        }
        return (tagsAdded, embeddingsAdded)
    }
}
