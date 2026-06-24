import Foundation
import ImageIO

/// 写真の主要メタ情報（EXIF/TIFF）。元画像データから抽出する Sendable な値オブジェクト。
public struct PhotoExifInfo: Sendable, Equatable {
    public var fileName: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var fNumber: Double?
    public var exposureTime: Double?   // 秒
    public var isoSpeed: Int?
    public var focalLength: Double?    // mm
    public var dateTimeOriginal: Date?

    public init() {}

    /// EXIF を含む元画像データから主要情報を抽出する（CPU 処理のためバックグラウンド推奨）。
    public static func parse(from data: Data, fileName: String? = nil) -> PhotoExifInfo {
        var info = PhotoExifInfo()
        info.fileName = fileName
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return info
        }
        info.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        info.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            info.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            info.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            info.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
            info.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                info.isoSpeed = isoArray.first
            }
            info.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                info.dateTimeOriginal = Self.exifDateFormatter.date(from: original)
            }
        }
        return info
    }

    /// 表示に使える情報が1つでもあるか。
    public var hasAny: Bool {
        cameraModel != nil || cameraMake != nil || lensModel != nil
            || fNumber != nil || exposureTime != nil || isoSpeed != nil
            || focalLength != nil || pixelWidth != nil
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
