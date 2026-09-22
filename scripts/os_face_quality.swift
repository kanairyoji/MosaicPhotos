// 顔の計測データセットに、**OS の顔品質（VNDetectFaceCaptureQualityRequest）**を付ける（ADR-220）。
//
// ⚠️ なぜ Mac で取るか: iOS シミュレータでは OS の品質モデルが動かず、`faceCaptureQuality` が
// 取れない（本番コードは nil を 1.0 として扱う）。計測ハーネスはシミュレータで回すので、
// これまで品質は**減点（ぼけ・向き・目閉じ・明るさ）だけ**で決まっていた。実機では OS の値が
// 効いて、同じ顔の多くが 0.1〜0.4 になる。Mac の Vision は同じ値を返すので、ここで取って
// 計測ハーネスが「実機相当の品質」を再現できるようにする。
//
// 使い方（Mac で）:
//   swiftc -O scripts/os_face_quality.swift -o /tmp/os_face_quality
//   /tmp/os_face_quality fgnet      # ~/DEV/tmp/face-eval/fgnet/os-quality.json（file → 品質）
//   /tmp/os_face_quality lfw
//   /tmp/os_face_quality pipa       # ~/DEV/tmp/face-eval-pipa/os-quality.json（faceID → 品質）
//
// FG-NET / LFW は「いちばん大きく写った顔」（計測ハーネスと同じ顔）の値。
// PIPA は計測に使った顔の枠をそのまま渡して、同じ顔の値を取る。
import AppKit
import Vision

func loadImage(_ path: String, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

let dataset = CommandLine.arguments.dropFirst().first ?? "fgnet"
var quality: [String: Float] = [:]
let outputPath: String

if dataset == "pipa" {
    let root = NSHomeDirectory() + "/DEV/tmp/face-eval-pipa"
    let cacheDir = root + "/cache-auraface-v1-r100"
    for file in (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? [] where file.hasSuffix(".json") {
        let photo = String(file.dropLast(5))
        guard let data = FileManager.default.contents(atPath: "\(cacheDir)/\(file)"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let faces = json["faces"] as? [[String: Any]], !faces.isEmpty,
              let image = loadImage("\(root)/images/\(photo).jpg", maxPixel: 2048) else { continue }
        let observations = faces.compactMap { face -> VNFaceObservation? in
            guard let box = face["box"] as? [Double], box.count == 4 else { return nil }
            return VNFaceObservation(boundingBox: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
        }
        let request = VNDetectFaceCaptureQualityRequest()
        request.inputFaceObservations = observations
        try? VNImageRequestHandler(cgImage: image).perform([request])
        for (index, result) in (request.results ?? []).enumerated() {
            if let q = result.faceCaptureQuality { quality["\(photo)#\(index)"] = q }
        }
    }
    outputPath = root + "/os-quality.json"
} else {
    let root = NSHomeDirectory() + "/DEV/tmp/face-eval/\(dataset)"
    let labels = (try? String(contentsOfFile: root + "/labels.csv", encoding: .utf8)) ?? ""
    for line in labels.split(whereSeparator: \.isNewline).dropFirst() {
        let file = String(line.split(separator: ",")[0])
        guard let image = loadImage("\(root)/images/\(file)", maxPixel: 1024) else { continue }
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        if let best = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
           let q = best.faceCaptureQuality { quality[file] = q }
    }
    outputPath = root + "/os-quality.json"
}

let data = try JSONSerialization.data(withJSONObject: quality, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: outputPath))
print("\(dataset): \(quality.count) 顔 → \(outputPath)")
