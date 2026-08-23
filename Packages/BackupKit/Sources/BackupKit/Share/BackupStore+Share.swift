import Foundation
import SwiftData

/// 共有セット（家族共有）の永続化。BackupKit コンテナ（BackupStore actor）に相乗りする
/// （@Model 追加は additive＝新テーブルなのでコンテナ名の採番は不要）。
extension BackupStore {

    // MARK: - セット

    /// セットを作成する。フォルダ名は既存セットと衝突しないようサニタイズ済みを渡す。
    public func createShareSet(name: String, folderName: String,
                               sourceKey: String? = nil) -> ShareSetLite {
        let set = ShareSet(name: name, folderName: folderName, sourceKey: sourceKey)
        modelContext.insert(set)
        try? modelContext.save()
        return ShareSetLite(id: set.id, name: set.name, folderName: set.folderName,
                            createdAt: set.createdAt, sidecarChecksum: nil, sourceKey: sourceKey)
    }

    public func allShareSets() -> [ShareSetLite] {
        let sets = (try? modelContext.fetch(FetchDescriptor<ShareSet>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return sets.map {
            ShareSetLite(id: $0.id, name: $0.name, folderName: $0.folderName,
                         createdAt: $0.createdAt, sidecarChecksum: $0.sidecarChecksum,
                         sourceKey: $0.sourceKey)
        }
    }

    /// セットと配下アイテムの記録を削除する（Dropbox 側の削除は呼び出し側の責務）。
    public func deleteShareSet(id: UUID) {
        let setID = id
        if let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == setID })).first {
            modelContext.delete(set)
        }
        let items = (try? modelContext.fetch(FetchDescriptor<ShareItem>(
            predicate: #Predicate { $0.setID == setID }))) ?? []
        for item in items { modelContext.delete(item) }
        try? modelContext.save()
    }

    public func setShareSidecarChecksum(setID: UUID, checksum: String?) {
        let id = setID
        guard let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == id })).first else { return }
        set.sidecarChecksum = checksum
        try? modelContext.save()
    }

    // MARK: - アイテム

    /// refKey 群をセットへ追加する（既存はスキップ）。追加できた件数を返す。
    public func addShareItems(setID: UUID, refKeys: [String]) -> Int {
        let id = setID
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<ShareItem>(
            predicate: #Predicate { $0.setID == id }))) ?? []).map(\.refKey))
        var added = 0
        for refKey in refKeys where !existing.contains(refKey) && !refKey.isEmpty {
            modelContext.insert(ShareItem(setID: setID, refKey: refKey))
            added += 1
        }
        if added > 0 { try? modelContext.save() }
        return added
    }

    public func shareItems(setID: UUID) -> [ShareItemLite] {
        let id = setID
        let items = (try? modelContext.fetch(FetchDescriptor<ShareItem>(
            predicate: #Predicate { $0.setID == id },
            sortBy: [SortDescriptor(\.addedAt, order: .forward)]))) ?? []
        return items.map {
            ShareItemLite(refKey: $0.refKey, sourcePath: $0.sourcePath,
                          sharedPath: $0.sharedPath, sharedContentHash: $0.sharedContentHash,
                          state: ShareItemState(rawValue: $0.stateRaw) ?? .pending,
                          addedAt: $0.addedAt)
        }
    }

    /// アイテム記録を削除する（Dropbox 側の削除は呼び出し側の責務）。
    public func removeShareItems(setID: UUID, refKeys: [String]) {
        let id = setID
        let keys = Set(refKeys)
        let items = (try? modelContext.fetch(FetchDescriptor<ShareItem>(
            predicate: #Predicate { $0.setID == id }))) ?? []
        for item in items where keys.contains(item.refKey) { modelContext.delete(item) }
        try? modelContext.save()
    }

    /// 反映結果の記録（コピー成功/失敗/バックアップ待ち）。
    public func updateShareItems(setID: UUID,
                                 updates: [(refKey: String, state: ShareItemState,
                                            sourcePath: String?, sharedPath: String?,
                                            sharedContentHash: String?)]) {
        let id = setID
        let items = (try? modelContext.fetch(FetchDescriptor<ShareItem>(
            predicate: #Predicate { $0.setID == id }))) ?? []
        var byKey: [String: ShareItem] = [:]
        for item in items { byKey[item.refKey] = item }
        for update in updates {
            guard let item = byKey[update.refKey] else { continue }
            item.stateRaw = update.state.rawValue
            if let source = update.sourcePath { item.sourcePath = source }
            if let shared = update.sharedPath {
                item.sharedPath = shared.lowercased()
                item.copiedAt = Date()
            }
            if let hash = update.sharedContentHash { item.sharedContentHash = hash }
        }
        try? modelContext.save()
    }

    /// 共有待ち（waitingBackup / pending）の端末写真 localIdentifier。
    /// バックアップ隊列の優先対象（ADR-112 追記: 共有に選ばれた写真から先にバックアップする）。
    public func shareWaitingLocalIdentifiers() -> Set<String> {
        let items = (try? modelContext.fetch(FetchDescriptor<ShareItem>())) ?? []
        var out: Set<String> = []
        for item in items where item.refKey.hasPrefix("L-") {
            let state = ShareItemState(rawValue: item.stateRaw) ?? .pending
            if state == .waitingBackup || state == .pending {
                out.insert(String(item.refKey.dropFirst(2)))
            }
        }
        return out
    }

    // MARK: - バックアップ記録の参照（"L-" 写真の実体解決）

    /// localIdentifier → バックアップ記録（パス・ハッシュ）。共有計画の入力。
    public func backupRefs(forLocalIdentifiers ids: [String]) -> [String: SharePlanning.BackupRef] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        // localIdentifier は #Predicate の contains(Set) が組めないため全件から絞る
        // （バックアップ記録は数万件・メタのみで軽い。BackupStore actor 上なのでメインは塞がない）。
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var out: [String: SharePlanning.BackupRef] = [:]
        for record in records {
            guard let localID = record.localIdentifier, wanted.contains(localID) else { continue }
            out[localID] = SharePlanning.BackupRef(dropboxPath: record.dropboxPath,
                                                   contentHash: record.contentHash)
        }
        return out
    }
}
