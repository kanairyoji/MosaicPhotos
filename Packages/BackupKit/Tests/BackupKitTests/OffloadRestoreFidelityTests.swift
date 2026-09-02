import CoreGraphics
import DropboxCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BackupKit

/// オフロード後の**復元の忠実性**（ADR-168・条件 4）。
///
/// 端末から消したあと、その写真をユーザーが見る経路は「Dropbox から取得 → デコードして表示」と
/// 「`ShareTempFile` が Dropbox 上のファイル名で書き出して他アプリへ渡す」の 2 つしかない。
/// どちらも**名前の拡張子**と**実データの形式**が一致していることを前提にしている。
/// 編集結果（JPEG）を原画の名前（.HEIC）で上げると、見た目は同じでも受け取り側が型を誤る。
@Suite("Offload restore fidelity (bytes and format survive the round trip)")
struct OffloadRestoreFidelityTests {

    private typealias Descriptor = BackupRenditionNaming.ResourceDescriptor

    /// 四隅マーカー（左上=赤/右上=緑/左下=青/右下=黄）の JPEG＝「編集結果」の代役。
    private static func markerJPEG(width: Int = 64, height: Int = 64) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // CoreGraphics は左下原点。左上=赤 になるよう上半分を先に塗る。
        let quads: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2),
             CGColor(red: 1, green: 0, blue: 0, alpha: 1)),      // 左上 赤
            (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2),
             CGColor(red: 0, green: 1, blue: 0, alpha: 1)),      // 右上 緑
            (CGRect(x: 0, y: 0, width: width / 2, height: height / 2),
             CGColor(red: 0, green: 0, blue: 1, alpha: 1)),      // 左下 青
            (CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2),
             CGColor(red: 1, green: 1, blue: 0, alpha: 1)),      // 右下 黄
        ]
        for (rect, color) in quads {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0]
                                   as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// 四隅の色（赤/緑/青/黄 のどれに最も近いか）を粗く読む。
    private static func cornerColors(_ data: Data) throws -> [String] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext のバッファは上→下の行順。
        func name(atX x: Int, y: Int) -> String {
            let i = (y * w + x) * 4
            let r = pixels[i] > 127, g = pixels[i + 1] > 127, b = pixels[i + 2] > 127
            switch (r, g, b) {
            case (true, false, false): return "red"
            case (false, true, false): return "green"
            case (false, false, true): return "blue"
            case (true, true, false): return "yellow"
            default: return "other"
            }
        }
        let inset = 4
        return [name(atX: inset, y: inset), name(atX: w - inset, y: inset),
                name(atX: inset, y: h - inset), name(atX: w - inset, y: h - inset)]
    }

    @Test("編集結果は、名前の拡張子と実形式が一致したままクラウドから取り出せる")
    func editedRenditionSurvivesRoundTrip() async throws {
        let editedJPEG = try Self.markerJPEG()
        #expect(try Self.cornerColors(editedJPEG) == ["red", "green", "blue", "yellow"],
                "fixture: 四隅マーカーを作れていない")

        // 原画は HEIC、編集結果は JPEG（写真アプリの実際の組み合わせ）。
        let resources = [
            Descriptor(kind: .photo, originalFilename: "IMG_0001.HEIC",
                       uniformTypeIdentifier: "public.heic"),
            Descriptor(kind: .fullSizePhoto, originalFilename: "FullSizeRender.jpg",
                       uniformTypeIdentifier: "public.jpeg"),
        ]
        let selection = try #require(BackupRenditionNaming.select(resources))
        #expect(selection.isEdited)
        let filename = try #require(BackupRenditionNaming.filename(
            resources: resources, selection: selection, localIdentifier: "ABC-1/L0/001",
            fallback: "fb.jpg", data: editedJPEG))

        // アップロード（検証つき）→ 同じパスから取得。
        let server = FakeDropboxServer()
        let uploader = DropboxBackupUploader(httpClient: server)
        let result = await uploader.upload(data: editedJPEG, to: "/backup/" + filename,
                                           token: "t",
                                           expectedHash: DropboxContentHash.hash(of: editedJPEG))
        guard case .uploaded(let savedPath, _) = result else {
            Issue.record("アップロードできていない: \(result)")
            return
        }
        let downloaded = try #require(await uploader.download(path: savedPath, token: "t"))

        // (a) 名前の拡張子から決まる型と、実データの型が一致する。
        let ext = (savedPath as NSString).pathExtension.lowercased()
        #expect(DeltaPageParser.imageExtensions.contains(ext),
                "Cloud 一覧に載らない拡張子＝アプリから見えなくなる")
        let declared = try #require(UTType(filenameExtension: ext))
        let source = try #require(CGImageSourceCreateWithData(downloaded as CFData, nil))
        let actual = try #require(CGImageSourceGetType(source) as String?)
        #expect(UTType(actual) == declared,
                "名前は \(ext) なのに中身は \(actual)（共有で他アプリへ誤った型として渡る）")

        // (b) デコードした見た目が、削除直前の編集結果と一致する。
        #expect(downloaded == editedJPEG, "バイト列が保全されていない")
        #expect(try Self.cornerColors(downloaded) == ["red", "green", "blue", "yellow"],
                "クラウドから取り出した写真の見た目が削除直前と違う")
    }
}
