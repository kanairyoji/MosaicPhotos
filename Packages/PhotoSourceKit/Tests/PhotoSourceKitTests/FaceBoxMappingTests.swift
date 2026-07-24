import CoreGraphics
import Testing
@testable import PhotoSourceKit

@Suite("FaceBoxMapping")
struct FaceBoxMappingTests {

    /// 正方形画像（クロップなし）は y 反転のみ。
    @Test("正方形はy反転のみ")
    func squareIdentity() {
        let rects = FaceBoxMapping.squareCropUnitRects(
            visionBoxes: [CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2)],
            aspectRatio: 1)
        #expect(rects.count == 1)
        // 左下原点 y=0.6,h=0.2 → 左上原点 y = 1-0.6-0.2 = 0.2
        #expect(abs(rects[0].origin.x - 0.1) < 1e-6)
        #expect(abs(rects[0].origin.y - 0.2) < 1e-6)
        #expect(abs(rects[0].width - 0.2) < 1e-6)
    }

    /// 横長 2:1 は中央の x∈[0.25,0.75] が表示される。中央の顔は拡大されてマップ。
    @Test("横長は中央クロップへ拡大マップ")
    func landscapeCenterFace() {
        let rects = FaceBoxMapping.squareCropUnitRects(
            visionBoxes: [CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)],
            aspectRatio: 2)
        #expect(rects.count == 1)
        // x' = (0.45-0.25)/0.5 = 0.4, w' = 0.1/0.5 = 0.2（y は無補正）
        #expect(abs(rects[0].origin.x - 0.4) < 1e-6)
        #expect(abs(rects[0].width - 0.2) < 1e-6)
        #expect(abs(rects[0].origin.y - 0.4) < 1e-6)
        #expect(abs(rects[0].height - 0.2) < 1e-6)
    }

    /// 横長でクロップ外（左端）の顔は描かない。
    @Test("クロップ外の顔は除外")
    func croppedOutFaceDropped() {
        let rects = FaceBoxMapping.squareCropUnitRects(
            visionBoxes: [CGRect(x: 0.0, y: 0.4, width: 0.1, height: 0.2)],
            aspectRatio: 2)
        #expect(rects.isEmpty)
    }

    /// 縦長 1:2 は中央の y が表示される（x は無補正）。
    @Test("縦長は上下クロップ")
    func portraitMapsVertically() {
        // 元画像の中央（y=0.45..0.55 付近）の顔。クロップは y∈[0.25,0.75]。
        let rects = FaceBoxMapping.squareCropUnitRects(
            visionBoxes: [CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.1)],
            aspectRatio: 0.5)
        #expect(rects.count == 1)
        // topY = 1-0.45-0.1 = 0.45 → y' = (0.45-0.25)/0.5 = 0.4, h' = 0.1/0.5 = 0.2
        #expect(abs(rects[0].origin.y - 0.4) < 1e-6)
        #expect(abs(rects[0].height - 0.2) < 1e-6)
        #expect(abs(rects[0].origin.x - 0.4) < 1e-6)
    }

    /// 不正アスペクト（0 以下）は補正なし（1 扱い）で落ちない。
    @Test("不正アスペクトは1扱い")
    func invalidAspectFallsBack() {
        let rects = FaceBoxMapping.squareCropUnitRects(
            visionBoxes: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)],
            aspectRatio: 0)
        #expect(rects.count == 1)
    }
}
