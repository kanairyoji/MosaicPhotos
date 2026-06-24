import CoreLocation
import Foundation
import Testing
@testable import DropboxKit

// MARK: - DropboxAPIArgEncoder (4 tests)

@Suite("DropboxAPIArgEncoder")
struct DropboxAPIArgEncoderTests {
    struct Simple: Encodable { let path: String }
    struct Multi: Encodable { let path: String; let size: String }

    @Test("ASCII-only value passes through unchanged")
    func asciiPassthrough() {
        let result = encodeDropboxAPIArg(Simple(path: "/photo.jpg"))
        #expect(result == #"{"path":"\/photo.jpg"}"#)
    }

    @Test("Non-ASCII Unicode is \\uXXXX escaped")
    func nonAsciiEscaped() {
        let result = encodeDropboxAPIArg(Simple(path: "/写真.jpg"))
        #expect(result?.contains("\\u") == true)
        #expect(result?.contains("写") == false)
    }

    @Test("Supplementary plane character is encoded as surrogate pair")
    func supplementaryCharSurrogatePair() {
        // U+1F600 (😀) is above U+FFFF — must produce a surrogate pair (\\uD83D...)
        let result = encodeDropboxAPIArg(Simple(path: "/😀.jpg"))
        let lower = result?.lowercased() ?? ""
        #expect(lower.contains("\\ud83d"))
    }

    @Test("Struct with multiple fields encodes all fields")
    func multipleFields() {
        let result = encodeDropboxAPIArg(Multi(path: "/a.jpg", size: "w256h256"))
        #expect(result?.contains("w256h256") == true)
        #expect(result?.contains("path") == true)
    }
}

// MARK: - DropboxFileItem (2 tests)

@Suite("DropboxFileItem")
struct DropboxFileItemTests {
    @Test("id equals path")
    func idEqualsPath() {
        let item = DropboxFileItem(path: "/folder/photo.jpg", name: "photo.jpg")
        #expect(item.id == "/folder/photo.jpg")
    }

    @Test("nameWithoutExtension strips extension")
    func nameWithoutExtension() {
        let item = DropboxFileItem(path: "/folder/my photo.heic", name: "my photo.heic")
        #expect(item.nameWithoutExtension == "my photo")
    }

    @Test("coordinate is non-nil only when both latitude and longitude are present")
    func coordinateRequiresBoth() {
        let both = DropboxFileItem(path: "/a.jpg", name: "a.jpg", latitude: 35.6, longitude: 139.7)
        #expect(both.coordinate?.latitude == 35.6)
        #expect(both.coordinate?.longitude == 139.7)

        let latOnly = DropboxFileItem(path: "/b.jpg", name: "b.jpg", latitude: 35.6, longitude: nil)
        #expect(latOnly.coordinate == nil)

        let lonOnly = DropboxFileItem(path: "/c.jpg", name: "c.jpg", latitude: nil, longitude: 139.7)
        #expect(lonOnly.coordinate == nil)

        let neither = DropboxFileItem(path: "/d.jpg", name: "d.jpg")
        #expect(neither.coordinate == nil)
    }
}

