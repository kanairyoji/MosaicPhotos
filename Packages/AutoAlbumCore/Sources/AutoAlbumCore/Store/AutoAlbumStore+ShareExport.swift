import Foundation
import MosaicSupport
import SwiftData

/// 家族共有（ADR-112）向けの埋め込み輸出入。
/// - 輸出: 共有セットのサイドカーに載せる CLIP 埋め込みを refKey 指定で取り出す。
/// - 取り込み: 家族のサイドカー由来の埋め込みを登録し、夜間の自前解析（サムネ DL＋推論）を
///   省く。既存の埋め込みは上書きしない（受信側の自前解析が常に優先）。
extension AutoAlbumStore {

    /// 共有の輸出入で使う fetch はここを通す（**発行回数を数える**＝規模退行テストの土台・ADR-119）。
    ///
    /// ⚠️ 件数だけを検証するテストは、1 枚ずつ引く実装に戻しても通ってしまう
    /// （レビュー指摘）。**回数**を数えられて初めて規模比例の回帰を止められる。
    func countedFetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        PerfTrace.count("autoAlbumStore.fetch")
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// refKey → CLIP 埋め込み（Float16 パック済み）。存在するものだけ返す。
    ///
    /// ⚠️ **1 回でまとめて引く**（ADR-119）。以前は refKey ごとに `fetchLimit = 1` で引いており、
    /// 共有の反映 1 回（最大 500 枚）につき 500 往復していた。同じ引数で呼ばれる兄弟
    /// （`TagStore` の `tags` / `ocrTexts` / `humanCounts` / `aesthetics`）は最初から
    /// `set.contains` の 1 回なので、**ここだけが揃っていなかった**。
    /// 変数上限の心当たりがあれば `fetchChunk` を小さくする（兄弟と同じリスク特性）。
    func embeddingsHalf(forRefKeys keys: [String]) -> [String: Data] {
        guard !keys.isEmpty else { return [:] }
        var out: [String: Data] = [:]
        for chunk in Self.refKeyChunks(keys) {
            let set = Set(chunk)
            let records = countedFetch(FetchDescriptor<PhotoEmbedding>(
                predicate: #Predicate { set.contains($0.refKey) }))
            for record in records { out[record.refKey] = record.vector }
        }
        return out
    }

    /// まとめ引きの分割単位。1 クエリに渡す条件が多すぎると SQLite の変数上限に当たるため、
    /// 一定数で切る（切っても往復は「件数 ÷ この値」で、件数に比例した往復にはならない）。
    static let fetchChunk = 400

    static func refKeyChunks(_ keys: [String]) -> [[String]] {
        let unique = Array(Set(keys))
        return stride(from: 0, to: unique.count, by: fetchChunk).map {
            Array(unique[$0..<min($0 + fetchChunk, unique.count)])
        }
    }

    /// 取り込み: 埋め込みが無い refKey にだけ登録する。登録できた件数を返す。
    /// enrichment 行が既にあれば sceneTagged を立て、夜間タガーの対象から外す。
    /// - Returns: 追加件数と**永続化できたか**（保存失敗を握り潰すと、取り込み済みとして
    ///   記録された後に中身が無い＝二度と取りに行かない状態になる・レビュー指摘）。
    func upsertImportedEmbeddings(_ batch: [(refKey: String, vectorHalf: Data)]) -> (added: Int, saved: Bool) {
        var added = 0
        for entry in batch {
            let key = entry.refKey
            var embDesc = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == key })
            embDesc.fetchLimit = 1
            guard (try? modelContext.fetch(embDesc).first) == nil else { continue }
            modelContext.insert(PhotoEmbedding(refKey: key, vector: entry.vectorHalf))
            added += 1
            var enrDesc = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == key })
            enrDesc.fetchLimit = 1
            if let enrichment = try? modelContext.fetch(enrDesc).first {
                enrichment.sceneTagged = true
            }
        }
        guard added > 0 else { return (0, true) }
        do {
            try modelContext.save()
            return (added, true)
        } catch {
            Self.log.error("upsertImportedEmbeddings: save failed — \(error)")
            modelContext.rollback()
            return (0, false)
        }
    }

    /// 夜間タガーの採用パス: 未埋め込み扱いの refKey のうち、取り込み済み埋め込みが既に
    /// あるものは sceneTagged を立てて「処理済み」に採用し、そのキー集合を返す
    /// （タガーはこれを除外して推論をスキップする）。
    func adoptImportedEmbeddings(refKeys: [String]) -> Set<String> {
        guard !refKeys.isEmpty else { return [] }
        // ⚠️ ここも 1 枚ずつ引かない（上と同じ理由）。夜間タガーは 512 件のページで呼ぶので、
        // 1 枚ずつだと 1 ページあたり最大 1,024 往復（埋め込み＋enrichment）になっていた。
        var adopted: Set<String> = []
        for chunk in Self.refKeyChunks(refKeys) {
            let set = Set(chunk)
            let embedded = Set(countedFetch(FetchDescriptor<PhotoEmbedding>(
                predicate: #Predicate { set.contains($0.refKey) })).map(\.refKey))
            guard !embedded.isEmpty else { continue }
            let enrichments = countedFetch(FetchDescriptor<PhotoEnrichment>(
                predicate: #Predicate { set.contains($0.refKey) }))
            for enrichment in enrichments where embedded.contains(enrichment.refKey) {
                enrichment.sceneTagged = true
                adopted.insert(enrichment.refKey)
            }
        }
        if !adopted.isEmpty { try? modelContext.save() }
        return adopted
    }

    /// テスト用: `sceneTagged` が立っている refKey（採用の副作用を確かめる）。
    func sceneTaggedRefKeysForTesting() -> Set<String> {
        Set(((try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>())) ?? [])
            .filter(\.sceneTagged).map(\.refKey))
    }
}
