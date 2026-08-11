import Foundation
import Testing
@testable import MosaicSupport

/// 診断ログの**読み出し方**（ADR-99）。
///
/// 実フィードバック「デバッグログを見るところで固まる」の回帰。旧 `recentText()` は
/// (1) `queue.sync` で最大 512KB をメインスレッドで読み、(2) 全文を 1 つの `Text` に流していた。
/// SwiftUI は 1 つの `Text` のレイアウトを分割できないので、巨大文字列はそれだけで致命的になる。
/// ここでは「行単位で返す」「末尾を上限件数まで」という契約を固定する（描画側の前提）。
@Suite("DiagnosticsLog reading", .serialized)
struct DiagnosticsLogReadTests {

    @Test("行単位で返す（末尾の空行を含めない）")
    func returnsLines() async {
        let log = DiagnosticsLog.shared
        log.clear()
        log.append("alpha")
        log.append("beta")
        let lines = await log.recentLines()

        #expect(lines.allSatisfy { !$0.contains("\n") }, "行が分割されていない")
        #expect(lines.last?.isEmpty == false, "末尾に空行が混じっている")
        #expect(lines.contains { $0.hasSuffix("alpha") })
        #expect(lines.contains { $0.hasSuffix("beta") })
    }

    @Test("上限件数を超えたら末尾だけ返す（先頭ではなく最新を残す）")
    func capsToTail() async {
        let log = DiagnosticsLog.shared
        log.clear()
        for i in 0..<50 { log.append("line-\(i)") }

        let lines = await log.recentLines(maxLines: 10)
        #expect(lines.count == 10, "上限件数を超えて返している: \(lines.count)")
        #expect(lines.last?.hasSuffix("line-49") == true, "最新ではなく先頭を残している")
        #expect(!lines.contains { $0.hasSuffix("line-0") }, "古い行が残っている")
    }

    @Test("空のログでは空配列（画面は「まだありません」を出せる）")
    func emptyLogReturnsEmpty() async {
        let log = DiagnosticsLog.shared
        log.clear()
        // clear() はバージョン行を 1 行だけ残す仕様。行が積み上がっていないことを見る。
        let lines = await log.recentLines()
        #expect(lines.count <= 1)
    }
}
