#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

@Suite("DropboxCacheNaming")
struct DropboxCacheNamingTests {

    @Test("hash は決定的な 64 桁 16 進文字列")
    func hashDeterministic() {
        let h = DropboxCacheNaming.hash("/photos/a.jpg")
        #expect(h == DropboxCacheNaming.hash("/photos/a.jpg"))   // 決定的
        #expect(h.count == 64)                                   // SHA256 = 32 bytes
        #expect(h.allSatisfy { $0.isHexDigit })
        #expect(DropboxCacheNaming.hash("/photos/b.jpg") != h)   // 異なるパスは別ハッシュ
    }

    @Test("サムネイルは常に .jpg")
    func thumbnailExtension() {
        let name = DropboxCacheNaming.fileName(kind: .thumbnail, path: "/x/photo.HEIC")
        #expect(name.hasSuffix(".jpg"))
        #expect(name == "\(DropboxCacheNaming.hash("/x/photo.HEIC")).jpg")
    }

    @Test("本体は元の拡張子を小文字で保持、無ければ bin")
    func fullImageExtension() {
        #expect(DropboxCacheNaming.fileName(kind: .fullImage, path: "/x/photo.HEIC").hasSuffix(".heic"))
        #expect(DropboxCacheNaming.fileName(kind: .fullImage, path: "/x/noext").hasSuffix(".bin"))
    }
}
#endif
