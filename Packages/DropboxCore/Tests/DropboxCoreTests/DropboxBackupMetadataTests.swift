import Foundation
import Testing
@testable import DropboxCore

@Suite("DropboxBackupMetadata")
struct DropboxBackupMetadataTests {

    @Test("people(for:) はパスの大文字小文字を無視して検索する")
    func peopleCaseInsensitive() {
        let meta = DropboxBackupMetadata(entries: [
            "/photos/a.jpg": .init(people: ["Alice", "Bob"]),
        ])
        #expect(meta.people(for: "/photos/a.jpg") == ["Alice", "Bob"])
        #expect(meta.people(for: "/Photos/A.JPG") == ["Alice", "Bob"])
        #expect(meta.people(for: "/unknown.jpg") == [])
    }

    @Test("merging は新エントリで既存キーを上書きし、他は保持する")
    func mergingOverwrites() {
        let base = DropboxBackupMetadata(entries: [
            "/a.jpg": .init(people: ["Old"]),
            "/b.jpg": .init(people: ["Keep"]),
        ])
        let merged = base.merging([
            "/a.jpg": .init(people: ["New"]),
            "/c.jpg": .init(people: ["Added"]),
        ])
        #expect(merged.entries["/a.jpg"]?.people == ["New"])    // 上書き
        #expect(merged.entries["/b.jpg"]?.people == ["Keep"])   // 保持
        #expect(merged.entries["/c.jpg"]?.people == ["Added"])  // 追加
        #expect(merged.entries.count == 3)
    }

    @Test("Codable 往復で entries が保たれる")
    func codableRoundTrip() throws {
        let meta = DropboxBackupMetadata(entries: [
            "/x.jpg": .init(people: ["P"], albums: ["Trip"], isFavorite: true,
                            date: "2021-01-01T00:00:00Z", contentHash: "abc"),
        ])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(DropboxBackupMetadata.self, from: data)
        let entry = try #require(decoded.entries["/x.jpg"])
        #expect(entry.people == ["P"])
        #expect(entry.albums == ["Trip"])
        #expect(entry.isFavorite)
        #expect(entry.date == "2021-01-01T00:00:00Z")
        #expect(entry.contentHash == "abc")
        #expect(decoded.version == 1)
    }

    // MARK: - BackupMetadataMerging（取得完了順に依存しない結合・ADR-38 読み込み側）

    /// 取得側（`withTaskGroup`）の「index でスロットへ代入 → スロット順にマージ」を模した組み立て。
    /// `arrivals` は**完了順**（先に完了したものが先頭）。
    private func mergedBySlots(
        pathCount: Int, arrivals: [(Int, DropboxBackupMetadata?)]
    ) -> DropboxBackupMetadata {
        var slots = [DropboxBackupMetadata?](repeating: nil, count: pathCount)
        for (index, part) in arrivals { slots[index] = part }
        return BackupMetadataMerging.merge(ordered: slots)
    }

    /// jsonPaths = [v1, shard(v2)]。v1 は凍結され、更新は v2 シャードにだけ書かれる。
    private var v1: DropboxBackupMetadata {
        DropboxBackupMetadata(entries: [
            "/backup/a.jpg": .init(people: ["旧姓"], albums: ["旧アルバム"], isFavorite: false),
            "/backup/only-v1.jpg": .init(people: ["V1Only"]),
        ])
    }
    private var v2: DropboxBackupMetadata {
        DropboxBackupMetadata(entries: [
            "/backup/a.jpg": .init(people: ["新姓"], albums: ["新アルバム"], isFavorite: true,
                                   offloadedAt: "2026-01-01T00:00:00Z"),
            "/backup/only-v2.jpg": .init(people: ["V2Only"]),
        ])
    }

    @Test("同一パスが v1 と v2 にあるとき、v2 の取得が先に完了しても最終値は v2")
    func v2WinsWhenV1CompletesLast() {
        // 完了順: v2（index 1）が先、v1（index 0）が後。旧実装（完了順マージ）では v1 が勝っていた。
        let merged = mergedBySlots(pathCount: 2, arrivals: [(1, v2), (0, v1)])
        let entry = merged.entries["/backup/a.jpg"]
        #expect(entry?.people == ["新姓"])
        #expect(entry?.albums == ["新アルバム"])
        #expect(entry?.isFavorite == true)
        #expect(entry?.offloadedAt == "2026-01-01T00:00:00Z")
    }

    @Test("v1 を遅らせた場合と v2 を遅らせた場合で結果が同一（完了順非依存）")
    func mergeIsIndependentOfCompletionOrder() {
        let v1Late = mergedBySlots(pathCount: 2, arrivals: [(1, v2), (0, v1)])
        let v2Late = mergedBySlots(pathCount: 2, arrivals: [(0, v1), (1, v2)])
        #expect(v1Late.entries.count == v2Late.entries.count)
        for (key, entry) in v1Late.entries {
            let other = v2Late.entries[key]
            #expect(entry.people == other?.people)
            #expect(entry.albums == other?.albums)
            #expect(entry.isFavorite == other?.isFavorite)
            #expect(entry.offloadedAt == other?.offloadedAt)
        }
        // 3 ファイル（v1 ＋ シャード 2 枚）でも、どの順に完了しても同じ。
        let s1 = DropboxBackupMetadata(entries: ["/backup/a.jpg": .init(people: ["S1"])])
        let s2 = DropboxBackupMetadata(entries: ["/backup/a.jpg": .init(people: ["S2"])])
        let orders: [[(Int, DropboxBackupMetadata?)]] = [
            [(0, v1), (1, s1), (2, s2)],
            [(2, s2), (0, v1), (1, s1)],
            [(1, s1), (2, s2), (0, v1)],
        ]
        for arrivals in orders {
            // 最後のスロット（最新のシャード）が勝つ。
            #expect(mergedBySlots(pathCount: 3, arrivals: arrivals)
                .entries["/backup/a.jpg"]?.people == ["S2"])
        }
    }

    @Test("v1 のみ・v2 のみ・複数ルートでも全エントリが読み込まれる")
    func mergeKeepsAllEntriesForSingleSourceAndMultipleRoots() {
        // v1 のみ（v2 シャード無し＝スロットは nil）。
        let onlyV1 = mergedBySlots(pathCount: 2, arrivals: [(0, v1), (1, nil)])
        #expect(onlyV1.entries.count == 2)
        #expect(onlyV1.entries["/backup/a.jpg"]?.people == ["旧姓"])
        #expect(onlyV1.entries["/backup/only-v1.jpg"]?.people == ["V1Only"])

        // v2 のみ（v1 ファイル不在）。
        let onlyV2 = mergedBySlots(pathCount: 2, arrivals: [(1, v2), (0, nil)])
        #expect(onlyV2.entries.count == 2)
        #expect(onlyV2.entries["/backup/a.jpg"]?.people == ["新姓"])
        #expect(onlyV2.entries["/backup/only-v2.jpg"]?.people == ["V2Only"])

        // 複数ルート（ルート A の v1/シャード ＋ ルート B の v1/シャード）。
        let bV1 = DropboxBackupMetadata(entries: ["/b/x.jpg": .init(people: ["BV1"])])
        let bV2 = DropboxBackupMetadata(entries: ["/b/y.jpg": .init(people: ["BV2"])])
        let all = mergedBySlots(pathCount: 4, arrivals: [(3, bV2), (0, v1), (2, bV1), (1, v2)])
        #expect(all.entries.count == 5)
        #expect(all.entries["/backup/a.jpg"]?.people == ["新姓"])
        #expect(all.entries["/backup/only-v1.jpg"]?.people == ["V1Only"])
        #expect(all.entries["/backup/only-v2.jpg"]?.people == ["V2Only"])
        #expect(all.entries["/b/x.jpg"]?.people == ["BV1"])
        #expect(all.entries["/b/y.jpg"]?.people == ["BV2"])
    }

    @Test("すべて nil のスロットは空のメタデータになる")
    func mergeOfAllNilIsEmpty() {
        #expect(BackupMetadataMerging.merge(ordered: [nil, nil]).entries.isEmpty)
    }

    @Test("Entry の任意フィールド（date / contentHash）は省略時 nil でデコードできる")
    func entryOptionalFieldsDecodeAsNil() throws {
        // date / contentHash は省略可（Optional）。people / albums / isFavorite は必須。
        let json = #"{ "people": ["Solo"], "albums": [], "isFavorite": false }"#
        let entry = try JSONDecoder().decode(
            DropboxBackupMetadata.Entry.self, from: Data(json.utf8))
        #expect(entry.people == ["Solo"])
        #expect(entry.albums == [])
        #expect(entry.isFavorite == false)
        #expect(entry.date == nil)
        #expect(entry.contentHash == nil)
    }
}
