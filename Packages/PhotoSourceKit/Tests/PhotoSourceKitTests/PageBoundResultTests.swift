import Foundation
import Testing
@testable import PhotoSourceKit

/// ⚠️ 取得・書き込みの待ち時間中も横ページ送りができる。開始時のページと完了時のページを
/// 突き合わせないと、共有では**見ている写真と違う写真を外部へ送り**、お気に入りでは
/// **別ページのハートを巻き戻す**（レビュー指摘）。
@Suite("PageBoundResult")
struct PageBoundResultTests {

    @Test("同じページのままなら反映してよい")
    func presentsWhenStillOnSamePage() {
        #expect(PageBoundResult.shouldPresent(startedOn: "A", current: "A"))
    }

    @Test("別ページへ移っていたら反映しない（共有の取り違え防止）")
    func doesNotPresentAfterPaging() {
        #expect(!PageBoundResult.shouldPresent(startedOn: "A", current: "B"),
                "A で始めた共有が B の表示中に開いてしまう")
    }

    @Test("戻ってきていれば反映してよい（A→B→A）")
    func presentsWhenReturnedToStartPage() {
        #expect(PageBoundResult.shouldPresent(startedOn: "A", current: "A"))
    }

    @Test("巻き戻し先は常に開始時のページ")
    func rollbackTargetsStartPage() {
        #expect(PageBoundResult.rollbackTarget(startedOn: "A") == "A")
    }
}

/// 共有は**原本**（フル解像度・EXIF・元のファイル名）を渡す。表示用の縮小画像を渡すと
/// 解像度・メタ情報・元の形式が失われる（レビュー指摘）。
@Suite("ShareTempFile")
struct ShareTempFileTests {

    @Test("原本は元のファイル名のまま一時ファイルへ書き出される")
    func writesWithOriginalFilename() throws {
        let data = Data("original-bytes".utf8)
        let original = SharedOriginal(data: data, filename: "IMG_0042.HEIC")

        let url = try #require(ShareTempFile.write(original))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "IMG_0042.HEIC", "共有先で名前・形式が変わる")
        #expect(try Data(contentsOf: url) == data, "バイト列が原本と違う（再エンコードしている）")
    }

    @Test("同じ写真を続けて共有しても上書きで書き出せる")
    func rewritesSameName() throws {
        let first = SharedOriginal(data: Data("a".utf8), filename: "IMG_1.JPG")
        let second = SharedOriginal(data: Data("bb".utf8), filename: "IMG_1.JPG")
        _ = ShareTempFile.write(first)
        let url = try #require(ShareTempFile.write(second))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == second.data)
    }
}
