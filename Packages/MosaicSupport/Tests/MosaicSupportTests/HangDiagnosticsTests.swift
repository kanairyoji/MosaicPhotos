#if canImport(MetricKit) && os(iOS)
import Foundation
import Testing
@testable import MosaicSupport

/// MetricKit ハング診断の呼び出し木パース（ADR-106）。
@Suite("HangDiagnostics")
struct HangDiagnosticsTests {

    @Test("callStackTree JSON から binary+offset+symbol の行を抜き出す")
    func parsesFrames() {
        let json = """
        {"callStacks":[{"callStackRootFrames":[
          {"binaryName":"MosaicPhotos","offsetIntoBinaryTextSegment":1234,
           "subFrames":[{"binaryName":"AutoAlbumCore","offsetIntoBinaryTextSegment":99,
                         "symbol":"doWork"}]}]}]}
        """.data(using: .utf8)!
        let lines = HangDiagnostics.topFrames(fromCallStackJSON: json, limit: 10)
        #expect(lines.count == 2)
        #expect(lines[0].contains("MosaicPhotos +1234"))
        #expect(lines[1].contains("AutoAlbumCore +99 doWork"))
    }

    @Test("壊れた JSON でもクラッシュせず目印を返す")
    func brokenJSONSafe() {
        let lines = HangDiagnostics.topFrames(fromCallStackJSON: Data("x".utf8), limit: 5)
        #expect(lines == ["(解析不能)"])
    }
}
#endif
