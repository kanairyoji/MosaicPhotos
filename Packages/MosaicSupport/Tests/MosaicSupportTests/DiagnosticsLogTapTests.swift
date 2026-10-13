import Foundation
import Testing
@testable import MosaicSupport

/// テストの聞き耳（`DiagnosticsLog.tap()`）の約束。
///
/// ⚠️ ログを `recentLines` で読む検査は、Mac に残った**前の実行の行**に当たって通り続けた
/// （ADR-278 のレビューで 2 回）。聞き耳はそれを仕組みで止めるためのもので、
/// 「立てる前の行は見えない」「ファイルが切り詰められても数が減らない」が壊れると、
/// 同じ空振りが静かに戻る。
@Suite("DiagnosticsLog の聞き耳")
struct DiagnosticsLogTapTests {

    private func makeLog() -> DiagnosticsLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tap-\(UUID().uuidString).log")
        return DiagnosticsLog(fileURL: url)
    }

    @Test("立てる前に書かれた行は見えず、後に書かれた行だけが見える")
    func seesOnlyLinesAfterTap() async {
        let log = makeLog()
        log.append("before-tap marker")
        // 前提: ファイルには前の行が在る（在るのに見えない、を確かめるため）。
        #expect(await log.recentLines().contains { $0.contains("before-tap marker") })

        let tap = log.tap()
        log.append("after-tap marker")
        #expect(await tap.count("before-tap marker") == 0, "立てる前の行が見えた")
        #expect(await tap.count("after-tap marker") == 1)
    }

    @Test("ファイルが切り詰められても、聞き耳の数は減らない")
    func countSurvivesTrimming() async {
        let log = makeLog()
        let tap = log.tap()
        log.append("needle")
        // 切り詰め（maxBytes の 2 倍）を確実に越える量を書く。
        let filler = String(repeating: "x", count: 1_000)
        for _ in 0..<(log.maxBytes * 2 / 1_000 + 50) { log.append(filler) }
        // 前提: ファイルからは needle が消えている（ここが崩れると何も確かめていない）。
        #expect(await log.recentLines(maxLines: 1_000_000).contains { $0.contains("needle") } == false)
        #expect(await tap.count("needle") == 1, "ファイルの切り詰めで聞き耳の行が消えた")
    }

    @Test("聞き耳を捨てたら、以後の行は覚えない（溜め続けない）")
    func releasedTapStopsRecording() async {
        let log = makeLog()
        var tap: DiagnosticsLog.Tap? = log.tap()
        #expect(tap != nil)
        tap = nil
        log.append("after release")
        _ = await log.recentLines()
        #expect(log.tapCountForTesting() == 0)
    }
}
