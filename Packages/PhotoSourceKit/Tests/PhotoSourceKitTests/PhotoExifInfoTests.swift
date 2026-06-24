import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoSourceKit

@Suite("PhotoExifInfo.parse")
struct PhotoExifInfoTests {

    struct MakeImageError: Error {}

    @Test("空データは空の情報（ファイル名のみ保持）")
    func emptyData() {
        let info = PhotoExifInfo.parse(from: Data(), fileName: "x.jpg")
        #expect(info.fileName == "x.jpg")
        #expect(!info.hasAny)
    }

    @Test("EXIF/TIFF（解像度・カメラ・F値・ISO・焦点距離）を抽出する")
    func parsesExifAndTiff() throws {
        let data = try makeJPEG(width: 4, height: 3,
                                make: "Apple", model: "iPhone 16",
                                fNumber: 2.8, iso: 100, focalLength: 26)
        let info = PhotoExifInfo.parse(from: data, fileName: "photo.jpg")
        #expect(info.fileName == "photo.jpg")
        #expect(info.pixelWidth == 4)
        #expect(info.pixelHeight == 3)
        #expect(info.cameraMake == "Apple")
        #expect(info.cameraModel == "iPhone 16")
        #expect(info.fNumber == 2.8)
        #expect(info.isoSpeed == 100)
        #expect(info.focalLength == 26)
        #expect(info.hasAny)
    }

    // MARK: - Helper

    /// 指定 EXIF/TIFF を埋め込んだ JPEG データを ImageIO で生成する。
    private func makeJPEG(width: Int, height: Int, make: String, model: String,
                          fNumber: Double, iso: Int, focalLength: Double) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { throw MakeImageError() }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw MakeImageError() }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: fNumber,
                kCGImagePropertyExifISOSpeedRatings: [iso],
                kCGImagePropertyExifFocalLength: focalLength,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MakeImageError() }
        return output as Data
    }
}
