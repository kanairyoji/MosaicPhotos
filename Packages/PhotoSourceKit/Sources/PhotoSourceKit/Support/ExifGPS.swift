import Foundation
import ImageIO

/// GPS 辞書（ImageIO の `kCGImagePropertyGPSDictionary`）から符号付き緯度経度を取り出す純ロジック。
/// EXIF GPS は magnitude を正値で持ち、Ref("N"/"S"・"E"/"W") で南/西を負にする。
/// `PHAsset.location` が nil の写真（コピー/取り込みで索引されない場合）の補完に使う。
public func parseExifGPS(_ gps: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
    guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
          let lon = gps[kCGImagePropertyGPSLongitude] as? Double
    else { return nil }
    let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
    let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
    return (
        latitude: latRef.uppercased() == "S" ? -lat : lat,
        longitude: lonRef.uppercased() == "W" ? -lon : lon
    )
}
