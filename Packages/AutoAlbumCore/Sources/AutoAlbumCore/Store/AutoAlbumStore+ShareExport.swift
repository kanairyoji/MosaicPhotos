import Foundation
import SwiftData

/// 家族共有（ADR-112）向けの埋め込み輸出入。
/// - 輸出: 共有セットのサイドカーに載せる CLIP 埋め込みを refKey 指定で取り出す。
/// - 取り込み: 家族のサイドカー由来の埋め込みを登録し、夜間の自前解析（サムネ DL＋推論）を
///   省く。既存の埋め込みは上書きしない（受信側の自前解析が常に優先）。
extension AutoAlbumStore {

    /// refKey → CLIP 埋め込み（Float16 パック済み）。存在するものだけ返す。
    func embeddingsHalf(forRefKeys keys: [String]) -> [String: Data] {
        guard !keys.isEmpty else { return [:] }
        let wanted = Set(keys)
        var out: [String: Data] = [:]
        for key in wanted {
            var d = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            if let record = try? modelContext.fetch(d).first {
                out[key] = record.vector
            }
        }
        return out
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
        var adopted: Set<String> = []
        for key in refKeys {
            var embDesc = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == key })
            embDesc.fetchLimit = 1
            guard (try? modelContext.fetch(embDesc).first) != nil else { continue }
            var enrDesc = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == key })
            enrDesc.fetchLimit = 1
            if let enrichment = try? modelContext.fetch(enrDesc).first {
                enrichment.sceneTagged = true
                adopted.insert(key)
            }
        }
        if !adopted.isEmpty { try? modelContext.save() }
        return adopted
    }
}
