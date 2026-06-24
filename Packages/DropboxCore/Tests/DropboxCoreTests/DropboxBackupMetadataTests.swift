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
