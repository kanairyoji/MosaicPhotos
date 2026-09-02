import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// ⚠️ 写真アプリで編集した写真は `.photo`（原画）と `.fullSizePhoto`（編集結果）の 2 つの
/// リソースを持つ。原画を上げると、クラウドに残るのは**画面に見えているものではない**。
/// しかもオフロードの直前検証も同じ読み取りを通るので、原画同士で一致して適格になり、
/// 編集結果を保全しないまま端末から消える（ADR-168）。
@Suite("Backup rendition selection and naming")
struct BackupRenditionNamingTests {

    private typealias Descriptor = BackupRenditionNaming.ResourceDescriptor

    private let original = Descriptor(kind: .photo, originalFilename: "IMG_0001.HEIC",
                                      uniformTypeIdentifier: "public.heic")
    /// 編集レンディション。`originalFilename` は写真ごとに一意ではない（名前に使えない）。
    private let editedJPEG = Descriptor(kind: .fullSizePhoto, originalFilename: "FullSizeRender.jpg",
                                        uniformTypeIdentifier: "public.jpeg")

    /// 12 バイト以上の JPEG（先頭バイトでの形式判定用）。
    private var jpegBytes: Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1]) }

    // MARK: - 選択

    @Test("編集済みなら編集結果（fullSizePhoto）を選ぶ")
    func picksEditedRendition() throws {
        let selection = try #require(BackupRenditionNaming.select([original, editedJPEG]))
        #expect(selection.index == 1, "原画を選ぶと画面に見えているものが保全されない")
        #expect(selection.isEdited)
    }

    @Test("未編集なら原画（photo）のまま＝従来の挙動")
    func picksOriginalWhenNotEdited() throws {
        let selection = try #require(BackupRenditionNaming.select([original]))
        #expect(selection.index == 0)
        #expect(!selection.isEdited)
    }

    @Test("リソースが無ければ選べない")
    func noResources() {
        #expect(BackupRenditionNaming.select([]) == nil)
    }

    // MARK: - 名前

    @Test("未編集の名前は変えない（既存バックアップを上げ直さない）")
    func unchangedNameForOriginal() throws {
        let selection = try #require(BackupRenditionNaming.select([original]))
        let name = BackupRenditionNaming.filename(
            resources: [original], selection: selection,
            localIdentifier: "ABC-1/L0/001", fallback: "fb.jpg", data: jpegBytes)
        #expect(name == "IMG_0001.HEIC")
    }

    @Test("編集結果は原画由来の一意な名前＋実データの形式に対応した拡張子")
    func editedNameUsesOriginalStemAndRealFormat() throws {
        let resources = [original, editedJPEG]
        let selection = try #require(BackupRenditionNaming.select(resources))
        let name = try #require(BackupRenditionNaming.filename(
            resources: resources, selection: selection,
            localIdentifier: "ABC-1/L0/001", fallback: "fb.jpg", data: jpegBytes))
        // 原画は HEIC でも編集結果は JPEG。原画の拡張子を流用すると .HEIC 名の JPEG になる。
        #expect(name == "IMG_0001-edited.jpg")
        let ext = (name as NSString).pathExtension.lowercased()
        #expect(DeltaPageParser.imageExtensions.contains(ext),
                "Cloud 一覧に載らない拡張子で上げている（共有もできない）")
    }

    @Test("UTI が取れなくても先頭バイトから形式を決める")
    func fallsBackToMagicBytes() throws {
        let noUTI = Descriptor(kind: .fullSizePhoto, originalFilename: "FullSizeRender",
                               uniformTypeIdentifier: nil)
        let resources = [original, noUTI]
        let selection = try #require(BackupRenditionNaming.select(resources))
        let name = BackupRenditionNaming.filename(
            resources: resources, selection: selection,
            localIdentifier: "ABC-1/L0/001", fallback: "fb.jpg", data: jpegBytes)
        #expect(name == "IMG_0001-edited.jpg")
    }

    @Test("形式が決められない編集結果は名前を作らない（＝上げない）")
    func refusesUnknownFormat() throws {
        let noUTI = Descriptor(kind: .fullSizePhoto, originalFilename: "FullSizeRender",
                               uniformTypeIdentifier: nil)
        let resources = [original, noUTI]
        let selection = try #require(BackupRenditionNaming.select(resources))
        let name = BackupRenditionNaming.filename(
            resources: resources, selection: selection, localIdentifier: "ABC-1/L0/001",
            fallback: "fb.jpg", data: Data(repeating: 0x2A, count: 32))
        #expect(name == nil, "形式不明のまま名前を付けると、実形式と食い違うファイルができる")
    }

    @Test("画像として扱えない形式（PDF 等）も名前を作らない")
    func refusesNonImageFormat() throws {
        let pdf = Descriptor(kind: .fullSizePhoto, originalFilename: "FullSizeRender.pdf",
                             uniformTypeIdentifier: "com.adobe.pdf")
        let resources = [original, pdf]
        let selection = try #require(BackupRenditionNaming.select(resources))
        #expect(BackupRenditionNaming.filename(
            resources: resources, selection: selection, localIdentifier: "ABC-1/L0/001",
            fallback: "fb.jpg", data: Data(repeating: 0x2A, count: 32)) == nil)
    }

    @Test("原画リソースが無ければ localIdentifier 由来の安定した stem を使う")
    func stableStemWhenNoOriginal() throws {
        let resources = [editedJPEG]
        let selection = try #require(BackupRenditionNaming.select(resources))
        let name = try #require(BackupRenditionNaming.filename(
            resources: resources, selection: selection,
            localIdentifier: "ABCDEF12-3456/L0/001", fallback: "fb.jpg", data: jpegBytes))
        #expect(name == "photo_ABCDEF12-edited.jpg",
                "FullSizeRender.jpg のような共通名を使うと写真どうしで衝突する")
    }

    // MARK: - 形式判定

    @Test("先頭バイトの形式判定（JPEG / PNG / HEIF / TIFF）")
    func sniffing() {
        #expect(BackupRenditionNaming.sniffExtension(jpegBytes) == "jpg")
        #expect(BackupRenditionNaming.sniffExtension(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])) == "png")
        var heic = Data([0, 0, 0, 0x18])
        heic.append(contentsOf: Array("ftypheic".utf8))
        heic.append(contentsOf: [0, 0, 0, 0])
        #expect(BackupRenditionNaming.sniffExtension(heic) == "heic")
        #expect(BackupRenditionNaming.sniffExtension(
            Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 0, 0, 0, 0])) == "tif")
        #expect(BackupRenditionNaming.sniffExtension(Data(repeating: 0, count: 16)) == nil)
    }
}
