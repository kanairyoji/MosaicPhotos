import Foundation
import Testing
@testable import DropboxCore

@Suite("DropboxMediaInfo decode")
struct DropboxMediaInfoTests {

    private func decode(_ json: String) throws -> DropboxMediaInfo {
        try JSONDecoder().decode(DropboxMediaInfo.self, from: Data(json.utf8))
    }

    @Test("location と time_taken を持つ media_info をデコードする")
    func full() throws {
        // Dropbox list_folder / get_metadata の media_info 形（.tag・dimensions は無視される）。
        let info = try decode("""
        {
          ".tag": "metadata",
          "metadata": {
            ".tag": "photo",
            "dimensions": { "height": 3024, "width": 4032 },
            "location": { "latitude": 35.681, "longitude": 139.767 },
            "time_taken": "2015-05-12T15:50:38Z"
          }
        }
        """)
        #expect(info.metadata?.location?.latitude == 35.681)
        #expect(info.metadata?.location?.longitude == 139.767)
        #expect(info.metadata?.time_taken == "2015-05-12T15:50:38Z")
    }

    @Test("pending（metadata 無し）は metadata が nil")
    func pending() throws {
        let info = try decode(#"{ ".tag": "pending" }"#)
        #expect(info.metadata == nil)
    }

    @Test("location が無い metadata は location nil・time_taken は保持")
    func metadataWithoutLocation() throws {
        let info = try decode("""
        { "metadata": { ".tag": "photo", "time_taken": "2020-01-02T03:04:05Z" } }
        """)
        #expect(info.metadata != nil)
        #expect(info.metadata?.location == nil)
        #expect(info.metadata?.time_taken == "2020-01-02T03:04:05Z")
    }

    @Test("time_taken が無い metadata は time_taken nil・location は保持")
    func metadataWithoutTimeTaken() throws {
        let info = try decode("""
        { "metadata": { "location": { "latitude": 1.5, "longitude": -2.5 } } }
        """)
        #expect(info.metadata?.time_taken == nil)
        #expect(info.metadata?.location?.latitude == 1.5)
        #expect(info.metadata?.location?.longitude == -2.5)
    }
}
