import Foundation
import Testing
@testable import BackupKit

/// Dropbox content_hash の実装検証（ADR-40・層 1）。
/// 期待値は Python hashlib で独立に計算した値（実装と同じコードで作らない＝循環しない）。
@Suite("DropboxContentHash")
struct DropboxContentHashTests {

    @Test("空データ")
    func empty() {
        #expect(DropboxContentHash.hash(of: Data())
            == "5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456")
    }

    @Test("1 ブロック未満（\"hello\"）")
    func singleBlock() {
        #expect(DropboxContentHash.hash(of: Data("hello".utf8))
            == "9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50")
    }

    @Test("複数ブロック（ブロック境界ちょうど・block=4）")
    func multiBlockExact() {
        // "abcdefgh" を 4 バイトブロックで: sha256(sha256("abcd")+sha256("efgh"))
        #expect(DropboxContentHash.hash(of: Data("abcdefgh".utf8), blockSize: 4)
            == "7d5473712172f9ec1494baa03da3d8734d12d385d1ca6340856771c3d93382e6")
    }

    @Test("複数ブロック（端数あり・block=4）")
    func multiBlockRemainder() {
        #expect(DropboxContentHash.hash(of: Data("abcdefghi".utf8), blockSize: 4)
            == "913f95a542c2202d67bc5fa0f30ddce47c6db6d5197f9c3be58d3b2252efbdfd")
    }

    @Test("スライス（非ゼロ startIndex の Data）でも正しい")
    func sliceData() {
        let full = Data("xxhello".utf8)
        let slice = full.dropFirst(2)   // startIndex != 0 の Data
        #expect(DropboxContentHash.hash(of: slice)
            == "9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50")
    }
}
