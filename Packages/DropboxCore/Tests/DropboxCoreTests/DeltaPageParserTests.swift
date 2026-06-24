import Foundation
import Testing
@testable import DropboxCore

@Suite("DeltaPageParser")
struct DeltaPageParserTests {

    private func parse(_ json: String) throws -> DeltaPage {
        try DeltaPageParser.parse(Data(json.utf8))
    }
    private func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

    @Test("画像ファイルを time_taken 優先・media_info 座標つきで追加する")
    func addsLocatedImage() throws {
        let page = try parse("""
        {"entries":[
          {".tag":"file","name":"a.jpg","path_lower":"/t/a.jpg","content_hash":"h",
           "client_modified":"2020-01-01T00:00:00Z",
           "media_info":{"metadata":{"location":{"latitude":35.5,"longitude":139.5},
                                     "time_taken":"2019-06-15T12:00:00Z"}}}
        ],"cursor":"c1","has_more":false}
        """)
        #expect(page.added.count == 1)
        let a = page.added[0]
        #expect(a.path == "/t/a.jpg")
        #expect(a.captureDate == iso("2019-06-15T12:00:00Z"))
        #expect(a.latitude == 35.5)
        #expect(a.longitude == 139.5)
        #expect(page.cursor == "c1")
        #expect(page.hasMore == false)
    }

    @Test("time_taken が無ければ client_modified、media_info pending は座標なし")
    func fallbackAndPending() throws {
        let page = try parse("""
        {"entries":[
          {".tag":"file","name":"b.jpg","path_lower":"/t/b.jpg","client_modified":"2021-02-03T04:05:06Z"},
          {".tag":"file","name":"c.jpg","path_lower":"/t/c.jpg",
           "client_modified":"2022-03-03T00:00:00Z","media_info":{".tag":"pending"}}
        ],"cursor":"c","has_more":true}
        """)
        #expect(page.added.count == 2)
        let b = page.added.first { $0.path == "/t/b.jpg" }!
        #expect(b.captureDate == iso("2021-02-03T04:05:06Z"))
        #expect(b.coordinate == nil)
        let c = page.added.first { $0.path == "/t/c.jpg" }!
        #expect(c.captureDate == iso("2022-03-03T00:00:00Z"))
        #expect(c.coordinate == nil)
        #expect(page.hasMore == true)
    }

    @Test("非画像は除外、deleted は removed、folder は subfolderPaths へ振り分ける")
    func routesEntries() throws {
        let page = try parse("""
        {"entries":[
          {".tag":"file","name":"a.jpg","path_lower":"/x/a.jpg","client_modified":"2020-01-01T00:00:00Z"},
          {".tag":"file","name":"notes.txt","path_lower":"/x/notes.txt"},
          {".tag":"deleted","path_lower":"/x/gone.jpg"},
          {".tag":"folder","path_lower":"/x/sub"}
        ],"cursor":"c","has_more":false}
        """)
        #expect(page.added.map(\.path) == ["/x/a.jpg"])
        #expect(page.removed == ["/x/gone.jpg"])
        #expect(page.subfolderPaths == ["/x/sub"])
    }

    @Test("空エントリは空のページ")
    func empty() throws {
        let page = try parse(#"{"entries":[],"cursor":"c0","has_more":false}"#)
        #expect(page.added.isEmpty && page.removed.isEmpty && page.subfolderPaths.isEmpty)
        #expect(page.cursor == "c0")
    }
}
