import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// メタデータ v2（ADR-38）の純ロジック検証：シャード名・グループ化・マージ・カタログ更新・
/// v1 JSON との相互読み（Entry の新フィールドはすべて Optional）。
@Suite("BackupMetadataPlanning (metadata v2)")
struct BackupMetadataPlanningTests {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func entry(_ people: [String] = []) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people)
    }

    @Test("shardName は UTC の撮影月・日付不明は undated")
    func shardNaming() {
        #expect(BackupMetadataV2.shardName(for: date("2025-08-14T10:00:00Z")) == "2025-08")
        // UTC 基準: JST 深夜（8/1 08:59 JST = 7/31 23:59 UTC）は前月に入る
        #expect(BackupMetadataV2.shardName(for: date("2025-07-31T23:59:00Z")) == "2025-07")
        #expect(BackupMetadataV2.shardName(for: nil) == "undated")
        #expect(BackupMetadataV2.shardSuffix("2025-08") == "/.mosaic/meta/2025-08.json")
    }

    @Test("groupedByShard は撮影月ごとにまとめる")
    func grouping() {
        let entries = [
            BackupMetadataPlanning.NewEntry(path: "/a/1.jpg", date: date("2025-08-01T00:00:00Z"), entry: entry()),
            BackupMetadataPlanning.NewEntry(path: "/a/2.jpg", date: date("2025-08-20T00:00:00Z"), entry: entry()),
            BackupMetadataPlanning.NewEntry(path: "/a/3.jpg", date: date("2025-09-01T00:00:00Z"), entry: entry()),
            BackupMetadataPlanning.NewEntry(path: "/a/4.jpg", date: nil, entry: entry()),
        ]
        let grouped = BackupMetadataPlanning.groupedByShard(entries)
        #expect(grouped.count == 3)
        #expect(grouped["2025-08"]?.count == 2)
        #expect(grouped["2025-09"]?.count == 1)
        #expect(grouped["undated"]?.count == 1)
    }

    @Test("mergedShard は既存へ上書きマージ・既存無しは新規作成")
    func shardMerge() throws {
        // 既存シャード（1 件）
        let existing = DropboxBackupMetadata(entries: ["/a/1.jpg": entry(["旧太郎"])])
        let existingData = try JSONEncoder().encode(existing)
        // 同キー上書き＋新キー追加
        let merged = BackupMetadataPlanning.mergedShard(
            existing: existingData,
            adding: ["/a/1.jpg": entry(["山田太郎"]), "/a/2.jpg": entry()])
        #expect(merged.entries.count == 2)
        #expect(merged.entries["/a/1.jpg"]?.people == ["山田太郎"])
        // 既存無し（初回）
        let fresh = BackupMetadataPlanning.mergedShard(existing: nil, adding: ["/a/3.jpg": entry()])
        #expect(fresh.entries.count == 1)
    }

    @Test("updatedCatalog はシャード追記（重複なし）＋アルバム/人物の全置換（空なら維持）")
    func catalogUpdate() throws {
        let base = BackupCatalog(shards: ["2025-07"], albums: ["旅行"], people: ["山田太郎"])
        let baseData = try JSONEncoder().encode(base)
        let updated = BackupMetadataPlanning.updatedCatalog(
            existing: baseData, touchedShards: ["2025-08", "2025-07"],
            albums: ["旅行", "家族"], people: ["山田太郎", "山田花子"])
        #expect(updated.shards == ["2025-07", "2025-08"])
        #expect(updated.albums == ["旅行", "家族"])
        #expect(updated.people == ["山田太郎", "山田花子"])
        // 空のアルバム/人物一覧では既存カタログを消さない（権限縮退時の保護）
        let kept = BackupMetadataPlanning.updatedCatalog(
            existing: baseData, touchedShards: [], albums: [], people: [])
        #expect(kept.albums == ["旅行"])
        #expect(kept.people == ["山田太郎"])
        // 既存無し（初回）
        let fresh = BackupMetadataPlanning.updatedCatalog(
            existing: nil, touchedShards: ["2025-08"], albums: ["A"], people: [])
        #expect(fresh.schemaVersion == 2)
        #expect(fresh.shards == ["2025-08"])
    }

    @Test("Entry v2: v1 の JSON を読める＋新フィールドがラウンドトリップする")
    func entryCompatibility() throws {
        // v1 形式（新フィールド無し）のデコード
        let v1JSON = #"{"people":["太郎"],"albums":["旅行"],"isFavorite":true}"#
        let v1 = try JSONDecoder().decode(DropboxBackupMetadata.Entry.self, from: Data(v1JSON.utf8))
        #expect(v1.people == ["太郎"])
        #expect(v1.localIdentifier == nil && v1.latitude == nil && v1.caption == nil)
        // v2 フィールドのラウンドトリップ
        let v2 = DropboxBackupMetadata.Entry(
            people: ["山田太郎"], albums: ["家族"], isFavorite: true,
            date: "2025-08-14T10:00:00Z", contentHash: "abc",
            localIdentifier: "ID-1/L0", latitude: 26.5, longitude: 127.9,
            isScreenshot: false, caption: "A boy at the beach")
        let decoded = try JSONDecoder().decode(DropboxBackupMetadata.Entry.self,
                                               from: JSONEncoder().encode(v2))
        #expect(decoded.localIdentifier == "ID-1/L0")
        #expect(decoded.latitude == 26.5)
        #expect(decoded.isScreenshot == false)
        #expect(decoded.caption == "A boy at the beach")
    }
}
