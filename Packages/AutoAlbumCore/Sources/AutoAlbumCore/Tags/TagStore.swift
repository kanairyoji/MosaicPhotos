import Foundation
import MosaicSupport
import SwiftData

/// 写真ごとの**シーンタグ**（Vision 分類・約1,300クラス・精度校正済み）と **VLM キャプション**
/// （SmolVLM・任意）の永続化。AI アルバムの「タグ台帳＋LLM 審査」検索の一次データ。
///
/// CLIP の `AutoAlbumStore` とは**別コンテナ**（"TagsV1"・FacesV1 と同じパターン）＝
/// タグ機能の追加・スキーマ変更で既存の埋め込みデータを壊さない。
@Model
final class PhotoTagRecord {
    @Attribute(.unique) var refKey: String
    /// Vision 分類の識別子（英語・precision フィルタ済み・最大 ~10 個）。
    var tags: [String]
    /// VLM の短文キャプション（英語）。未生成は nil（タグより後から埋まる）。
    var caption: String?
    /// タグ付けロジックの版（分類器・しきい値変更時に採番して再タグ）。
    var version: Int

    init(refKey: String, tags: [String], caption: String? = nil, version: Int) {
        self.refKey = refKey
        self.tags = tags
        self.caption = caption
        self.version = version
    }
}

/// タグ・キャプションの @ModelActor ストア。⚠️ 本番はオフメイン生成（@ModelActor は init した
/// スレッドで実行される・事例参照）。
@ModelActor
actor TagStore {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Tags")

    /// 現行のタグ付け版。
    static let currentVersion = 1

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([PhotoTagRecord.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return AutoAlbumStore.makeResilientContainer(name: "TagsV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    // MARK: - タグ付け進捗

    /// タグ付け済み（現行版）の refKey 集合。
    func taggedRefKeys() -> Set<String> {
        let v = Self.currentVersion
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.version >= v }))) ?? []
        return Set(records.map(\.refKey))
    }

    func taggedCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>())) ?? 0
    }

    func captionedCount() -> Int {
        (try? modelContext.fetchCount(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil }))) ?? 0
    }

    /// キャプション済みの (refKey, caption) を先頭から最大 limit 件返す（確認 UI 用）。
    func captionedSamples(limit: Int) -> [(refKey: String, caption: String)] {
        var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil },
                                                sortBy: [SortDescriptor(\.refKey)])
        d.fetchLimit = limit
        return ((try? modelContext.fetch(d)) ?? []).compactMap { r in
            guard let c = r.caption, !c.isEmpty else { return nil }
            return (refKey: r.refKey, caption: c)
        }
    }

    /// バッチ記録（save は 1 回）。既存レコードは更新（版を上げて再タグした場合も上書き）。
    func recordTags(_ batch: [(refKey: String, tags: [String])]) {
        for entry in batch {
            let key = entry.refKey
            var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            if let existing = try? modelContext.fetch(d).first {
                existing.tags = entry.tags
                existing.version = Self.currentVersion
            } else {
                modelContext.insert(PhotoTagRecord(refKey: key, tags: entry.tags, version: Self.currentVersion))
            }
        }
        try? modelContext.save()
    }

    // MARK: - キャプション（VLM・タグより後から埋まる）

    /// 既存キャプションを全消去する（VLM モデル差し替え時＝`captionModelVersion` 変更で 1 回）。
    /// caption を nil に戻すと `captionPending` が再び対象にし、新モデルで付け直される。
    func resetCaptions() -> Int {
        guard let records = try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil })) else { return 0 }
        for r in records { r.caption = nil }
        try? modelContext.save()
        return records.count
    }

    /// キャプション未生成（caption == nil）の件数。インターリーブの進捗判定に使う。
    /// `favorites` 指定時はその集合内のみ数える（キャプションはお気に入り限定のため）。
    func captionPendingCount(favorites: Set<String>? = nil) -> Int {
        if let favorites {
            guard !favorites.isEmpty else { return 0 }
            return (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>(
                predicate: #Predicate { favorites.contains($0.refKey) && $0.caption == nil }))) ?? 0
        }
        return (try? modelContext.fetchCount(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption == nil }))) ?? 0
    }

    /// キャプション未生成（タグ付けは済み）の refKey を返す（夜間トリクルの対象）。
    /// `favorites` 指定時はその集合内のみ（キャプションはお気に入り限定のため）。
    func captionPending(limit: Int, favorites: Set<String>? = nil) -> [String] {
        var d: FetchDescriptor<PhotoTagRecord>
        if let favorites {
            guard !favorites.isEmpty else { return [] }
            d = FetchDescriptor<PhotoTagRecord>(
                predicate: #Predicate { favorites.contains($0.refKey) && $0.caption == nil },
                sortBy: [SortDescriptor(\.refKey)])
        } else {
            d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption == nil },
                                                sortBy: [SortDescriptor(\.refKey)])
        }
        d.fetchLimit = limit
        return ((try? modelContext.fetch(d)) ?? []).map(\.refKey)
    }

    func recordCaptions(_ batch: [(refKey: String, caption: String)]) {
        for entry in batch {
            let key = entry.refKey
            var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            if let existing = try? modelContext.fetch(d).first {
                existing.caption = entry.caption
            } else {
                modelContext.insert(PhotoTagRecord(refKey: key, tags: [],
                                                   caption: entry.caption, version: 0))
            }
        }
        try? modelContext.save()
    }

    // MARK: - 検索用の取り出し

    /// 指定 refKey 群のタグ（IN 句・検索の候補評価用）。
    func tags(forRefKeys keys: [String]) -> [String: [String]] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: [String]] = [:]
        for r in records where !r.tags.isEmpty { out[r.refKey] = r.tags }
        return out
    }

    /// 全タグ台帳（refKey → tags）。検索の一次ランキングで使う（数万件・値は小さい）。
    func allTags() -> [String: [String]] {
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoTagRecord>())) ?? []
        var out: [String: [String]] = [:]
        out.reserveCapacity(records.count)
        for r in records where !r.tags.isEmpty { out[r.refKey] = r.tags }
        return out
    }

    /// 指定 refKey 群のキャプション（LLM Verify の入力用）。
    func captions(forRefKeys keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: String] = [:]
        for r in records { if let c = r.caption { out[r.refKey] = c } }
        return out
    }

    func reset() {
        try? modelContext.delete(model: PhotoTagRecord.self)
        try? modelContext.save()
    }
}
