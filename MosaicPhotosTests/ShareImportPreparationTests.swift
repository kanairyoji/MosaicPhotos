import AutoAlbumCore
import BackupKit
import DropboxKit
import XCTest
@testable import MosaicPhotos

/// 受信した解析データの組み立て（`ShareImportPreparation`）と、一覧が出そろったかの判断。
/// 以前は `SharedAnalysisImporter.runIfNeeded` のクロージャに直書きで、テストが届かなかった。
final class ShareImportPreparationTests: XCTestCase {

    private let versions = ShareImportPlanning.ReceiverVersions(tag: 1, perception: 1, face: 1)

    private func face(_ embedding: String) -> ShareAnalysisData.Face {
        ShareAnalysisData.Face(x: 0.1, y: 0.2, w: 0.3, h: 0.4, e: embedding, q: 0.9,
                               s: nil, d: nil, n: "Taro")
    }

    func testPiecesMatchByContentHashAndConvertCaptureDatesToLowercasedPaths() {
        let index = ShareImportPreparation.index(hashesByPath: ["/Camera/A.jpg": "ha"])
        let file = ShareAnalysisData.File(
            versions: .init(tag: 1, perception: 1, face: 1),
            entries: ["ha": .init(tags: ["dog"], faces: [face(Data([1, 2]).base64EncodedString()),
                                                         face("%%not-base64%%")],
                                  d: 1_000)])
        let pieces = ShareImportPreparation.pieces(of: file, index: index, versions: versions)

        XCTAssertTrue(pieces.fullyMatched)
        XCTAssertEqual(pieces.tags.map(\.refKey), ["C-/Camera/A.jpg"])
        XCTAssertEqual(pieces.tags.first?.info.tags, ["dog"])
        // 壊れた埋め込みの顔は落とし、読める顔だけ渡す。
        XCTAssertEqual(pieces.faces.count, 1)
        XCTAssertEqual(pieces.faces.first?.faces.count, 1)
        XCTAssertEqual(pieces.faces.first?.faces.first?.personName, "Taro")
        // 撮影日は refKey ではなく表示側が引く形（パス小文字）。
        XCTAssertEqual(pieces.captureDates, ["/camera/a.jpg": Date(timeIntervalSince1970: 1_000)])
    }

    /// 手元に無い写真の解析が混ざっていれば「全部突合できた」ではない（rev を記録しない）。
    func testUnmatchedEntryIsNotFullyMatched() {
        let index = ShareImportPreparation.index(hashesByPath: ["/a.jpg": "ha"])
        let file = ShareAnalysisData.File(
            versions: .init(tag: 1, perception: 1, face: 1),
            entries: ["ha": .init(tags: ["dog"]), "hb": .init(tags: ["cat"])])
        let pieces = ShareImportPreparation.pieces(of: file, index: index, versions: versions)
        XCTAssertFalse(pieces.fullyMatched)
        XCTAssertEqual(pieces.tags.count, 1, "突合できた分は取り込む")
    }

    func testShouldMarkImportedRequiresAllThree() {
        var marked = 0
        for matched in [false, true] {
            for committed in [false, true] {
                for landed in [false, true] {
                    let result = ShareImportPreparation.shouldMarkImported(
                        fullyMatched: matched, committed: committed, datesLanded: landed)
                    XCTAssertEqual(result, matched && committed && landed)
                    if result { marked += 1 }
                }
            }
        }
        XCTAssertEqual(marked, 1)
    }

    /// 「手元の一覧に無い＝もう無い」と読んでよいのは、一覧が出そろっているときだけ。
    func testListingSettledOnlyOutsideInitialSyncAndError() {
        typealias State = DropboxPhotoStore.SyncState
        XCTAssertFalse(State.initialSync(fetched: 10).isListingSettled)
        XCTAssertFalse(State.error("x").isListingSettled)
        XCTAssertTrue(State.idle.isListingSettled)
        XCTAssertTrue(State.polling.isListingSettled)
        XCTAssertTrue(State.fetchingDelta.isListingSettled)
    }
}
