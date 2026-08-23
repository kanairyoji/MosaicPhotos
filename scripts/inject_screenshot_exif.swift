// ドキュメント用スクリーンショット素材への EXIF 注入（撮影日・GPS）。
// `swift scripts/inject_screenshot_exif.swift` で実行する（外部依存なし・ImageIO のみ）。
//
// 入力: .screenshot_assets/raw/<都市名>-<N>.jpg
// 出力: .screenshot_assets/tagged/ に、都市ごとの GPS と「旅行らしい」日付を書き込んだコピー。
// これをシミュレータへ `simctl addmedia` すると、場所アルバム・旅行アルバム・日付グリッドが
// 本物のデータで埋まる（scripts/make_screenshot_sim.sh が使う）。
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct City {
    let name: String
    let lat: Double
    let lon: Double
    /// 旅行の開始日（この日から連番で数時間おきに散らす）。
    let start: DateComponents
    /// 旅行日数（この範囲に散らす）。
    let days: Int
}

let cities: [String: City] = [
    "okinawa": City(name: "Okinawa", lat: 26.2124, lon: 127.6809,
                    start: .init(year: 2025, month: 7, day: 20), days: 4),
    "kyoto":   City(name: "Kyoto", lat: 35.0116, lon: 135.7681,
                    start: .init(year: 2024, month: 11, day: 2), days: 3),
    "hakone":  City(name: "Hakone", lat: 35.2323, lon: 139.1069,
                    start: .init(year: 2025, month: 3, day: 15), days: 2),
    "tokyo":   City(name: "Tokyo", lat: 35.6812, lon: 139.7671,
                    start: .init(year: 2024, month: 4, day: 6), days: 400),   // 日常写真＝広く散らす
]
// misc-* は GPS なし（「場所なし」も混ぜて現実的にする）。

let fm = FileManager.default
let root = URL(fileURLWithPath: ".screenshot_assets")
let rawDir = root.appendingPathComponent("raw")
let outDir = root.appendingPathComponent("tagged")
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!

let exifFormatter = DateFormatter()
exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
exifFormatter.timeZone = calendar.timeZone

guard let files = try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil) else {
    print("no raw dir — run scripts/fetch_screenshot_photos.sh first")
    exit(1)
}

var written = 0
for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where file.pathExtension.lowercased() == "jpg" {
    let stem = file.deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-")
    guard parts.count == 2, let index = Int(parts[1]) else { continue }
    let cityKey = String(parts[0])

    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let type = CGImageSourceGetType(source) else { continue }
    var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any]) ?? [:]

    // 撮影日: 都市の旅行期間内に決定的に散らす（連番 × 数時間おき）。
    var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    let date: Date
    if let city = cities[cityKey] {
        let base = calendar.date(from: city.start)!
        let hoursSpread = city.days * 24
        let offsetHours = (index * 37) % hoursSpread            // 決定的・重ならない散らし
        date = calendar.date(byAdding: .hour, value: offsetHours + 9, to: base)!
        // GPS: 都市中心から少しずつずらす（同じ市区町村に収まる程度）。
        var gps: [CFString: Any] = [:]
        let jitter = Double((index * 7) % 20 - 10) * 0.002      // ±0.02 度
        gps[kCGImagePropertyGPSLatitude] = abs(city.lat + jitter)
        gps[kCGImagePropertyGPSLatitudeRef] = city.lat >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(city.lon + jitter * 1.3)
        gps[kCGImagePropertyGPSLongitudeRef] = city.lon >= 0 ? "E" : "W"
        properties[kCGImagePropertyGPSDictionary] = gps
    } else {
        // misc: GPS なし・日付だけ散らす。
        let base = calendar.date(from: .init(year: 2023, month: 6, day: 1))!
        date = calendar.date(byAdding: .day, value: index * 23, to: base)!
    }
    let stamp = exifFormatter.string(from: date)
    exif[kCGImagePropertyExifDateTimeOriginal] = stamp
    exif[kCGImagePropertyExifDateTimeDigitized] = stamp
    properties[kCGImagePropertyExifDictionary] = exif
    var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
    tiff[kCGImagePropertyTIFFDateTime] = stamp
    properties[kCGImagePropertyTIFFDictionary] = tiff

    let outURL = outDir.appendingPathComponent(file.lastPathComponent)
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, type, 1, nil) else { continue }
    CGImageDestinationAddImageFromSource(dest, source, 0, properties as CFDictionary)
    if CGImageDestinationFinalize(dest) { written += 1 }
}
print("tagged \(written) photos → \(outDir.path)")
