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
                            createdAt: set.createdAt, sourceKey: sourceKey)
    }

    public func allShareSets() -> [ShareSetLite] {
        let sets = (try? modelContext.fetch(FetchDescriptor<ShareSet>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return sets.map {
            ShareSetLite(id: $0.id, name: $0.name, folderName: $0.folderName,
                         createdAt: $0.createdAt, sourceKey: $0.sourceKey)
        }
    }

    /// セットごとのメンバー総数を **1 回の fetch** で数える（N+1 クエリを避ける）。
    ///
    /// ⚠️ 「共有済み何枚か」は**ここでは分からない**（ADR-209）。それは Dropbox の実在が
    /// 答えるもので、記録には無い。画面に出す数は反映のたびに数え直して
    /// `ShareSet.lastSyncedPresent` へ控える。
    public func shareItemTotals() -> [UUID: Int] {
        var descriptor = FetchDescriptor<ShareItem>()
        descriptor.propertiesToFetch = [\.setID]
        let items = (try? modelContext.fetch(descriptor)) ?? []
        var out: [UUID: Int] = [:]
        for item in items { out[item.setID, default: 0] += 1 }
        return out
    }

    /// セットごとの「最後の反映で共有済み / バックアップ待ちだった枚数」（表示の控え）。
    public func shareSyncedCounts() -> [UUID: (present: Int, waiting: Int)] {
        let sets = (try? modelContext.fetch(FetchDescriptor<ShareSet>())) ?? []
        var out: [UUID: (present: Int, waiting: Int)] = [:]
        for set in sets {
            out[set.id] = (set.lastSyncedPresent ?? 0, set.lastSyncedWaiting ?? 0)
        }
        return out
    }

    /// 反映の結果を控える（表示用）。
    public func recordShareSyncCounts(setID: UUID, present: Int, waiting: Int) {
        let id = setID
        guard let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == id })).first else { return }
        set.lastSyncedPresent = present
        set.lastSyncedWaiting = waiting
        try? modelContext.save()
    }

    /// 共有セットの件数（存在判定用・全件マテリアライズを避ける）。
    public func shareSetCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<ShareSet>())) ?? 0
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

    /// 作成元キーを更新する（同じ対象を作り直したときに最新の ID へ張り替える）。
    public func setShareSourceKey(setID: UUID, sourceKey: String) {
        let id = setID
        guard let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == id })).first else { return }
        set.sourceKey = sourceKey
        try? modelContext.save()
    }

    /// フォルダ名を変更する。
    ///
    /// ⚠️ Dropbox 側の旧フォルダは**触らない**（ADR-209）。フォルダも差分で収束するので、
    /// 旧フォルダは「望ましくないフォルダ」として次の反映が消し、新フォルダへコピーし直す。
    /// サーバーサイドコピーなので転送は起きない。
    public func renameShareSet(setID: UUID, folderName: String) {
        let id = setID
        guard let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == id })).first else { return }
        set.folderName = folderName
        set.lastSyncedPresent = nil
        try? modelContext.save()
    }

    /// 作成元キーを外す（人物 ID が振り直されたときなど、参照が当てにならなくなった場合）。
    public func clearShareSourceKey(setID: UUID) {
        let id = setID
        guard let set = try? modelContext.fetch(FetchDescriptor<ShareSet>(
            predicate: #Predicate { $0.id == id })).first else { return }
        set.sourceKey = nil
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
        return items.map { ShareItemLite(refKey: $0.refKey, addedAt: $0.addedAt) }
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

    /// **共有セットに入っている端末写真**の localIdentifier（全セットぶん）。
    ///
    /// バックアップ隊列はこのうち「まだバックアップされていないもの」を優先する
    /// （ADR-112 追記: 共有に選ばれた写真から先にバックアップする）。
    ///
    /// ⚠️ **ここで「まだバックアップされていない」まで求めない**（ADR-119）。
    /// それにはバックアップ記録の全件（数万行）が要るが、呼び出し側は**同じ集合を
    /// 既に持っている**（`computePending` の `doneIDs`）。ここで引き直すと、
    /// 1 回のバックアップで同じ数万行を 2 度読むことになる。
    /// 共有メンバーは数百〜数千なので、こちらだけを返して差し引きは呼び出し側に任せる。
    public func shareMemberLocalIdentifiers() -> Set<String> {
        var descriptor = FetchDescriptor<ShareItem>()
        descriptor.propertiesToFetch = [\.refKey]
        let items = (try? modelContext.fetch(descriptor)) ?? []
        return Set(items.map(\.refKey).filter { $0.hasPrefix("L-") }.map { String($0.dropFirst(2)) })
    }

    // MARK: - バックアップ記録の参照（"L-" 写真の実体解決）

    /// localIdentifier → バックアップ記録（パス・ハッシュ）。共有計画の入力。
    public func backupRefs(forLocalIdentifiers ids: [String]) -> [String: SharePlanning.BackupRef] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        // localIdentifier は #Predicate の contains(Set) が組めないため全件から絞る
        // （バックアップ記録は数万件・メタのみで軽い。BackupStore actor 上なのでメインは塞がない）。
        // メタ 3 列だけ取り出す（@Model 全体のマテリアライズは数万行でメモリを食う）。
        var descriptor = FetchDescriptor<BackupAssetRecord>()
        descriptor.propertiesToFetch = [\.localIdentifier, \.dropboxPath, \.contentHash]
        let records = (try? modelContext.fetch(descriptor)) ?? []
        var out: [String: SharePlanning.BackupRef] = [:]
        for record in records {
            guard let localID = record.localIdentifier, wanted.contains(localID) else { continue }
            out[localID] = SharePlanning.BackupRef(dropboxPath: record.dropboxPath,
                                                   contentHash: record.contentHash)
        }
        return out
    }
}
