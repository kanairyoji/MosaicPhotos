import UIKit

/// 画像の向きを検証する共通テストヘルパ（四隅オラクル）。
/// 四象限に別々の色（左上=赤/右上=緑/左下=青/右下=黄）を塗った非対称マーカー画像を作り、
/// 「向きを尊重してレンダリングした四象限の中心色」で向きの崩れを検出する。
/// Layer 1（純ロジック）・Layer 2（seam）・Layer 3（実経路）で共用する。
enum OrientationOracle {
    enum Corner: String { case red, green, blue, yellow, other }

    /// 非対称マーカー画像（.up）。四象限に赤/緑/青/黄。
    static func markerImage(width: CGFloat, height: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            let c = ctx.cgContext
            let w = width / 2, h = height / 2
            c.setFillColor(UIColor.red.cgColor);    c.fill(CGRect(x: 0, y: 0, width: w, height: h))   // 左上
            c.setFillColor(UIColor.green.cgColor);  c.fill(CGRect(x: w, y: 0, width: w, height: h))   // 右上
            c.setFillColor(UIColor.blue.cgColor);   c.fill(CGRect(x: 0, y: h, width: w, height: h))   // 左下
            c.setFillColor(UIColor.yellow.cgColor); c.fill(CGRect(x: w, y: h, width: w, height: h))   // 右下
        }
    }

    /// 画像を**向きを尊重して**レンダリングし、四象限の中心色を返す（[左上,右上,左下,右下]）。
    static func cornerColors(_ image: UIImage) -> [Corner] {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let cg = UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage!
        let w = cg.width, h = cg.height
        let points = [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
        return points.map { classify(pixel(cg, x: $0.0, y: $0.1)) }
    }

    /// CGImage の 1 画素 (x,y) の RGB を読む。
    static func pixel(_ cg: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height - 1 - y),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    static func classify(_ p: (r: Int, g: Int, b: Int)) -> Corner {
        let hi = 140, lo = 110
        switch (p.r, p.g, p.b) {
        case let (r, g, b) where r > hi && g < lo && b < lo: return .red
        case let (r, g, b) where g > hi && r < lo && b < lo: return .green
        case let (r, g, b) where b > hi && r < lo && g < lo: return .blue
        case let (r, g, b) where r > hi && g > hi && b < lo: return .yellow
        default: return .other
        }
    }
}
