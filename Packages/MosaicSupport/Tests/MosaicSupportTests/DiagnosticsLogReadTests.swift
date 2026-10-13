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

    /// ⚠️ `shared` は使わない。並列に走る他のテスト（熱ゲートの遷移記録など）が同じファイルへ
    /// 書き込み、`clear()` の直後に行が増えて落ちる。テストごとに自分のファイルを持つ。
    private func makeLog() -> DiagnosticsLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-test-\(UUID().uuidString).log")
        return DiagnosticsLog(fileURL: url)
    }

    @Test("行単位で返す（末尾の空行を含めない）")
    func returnsLines() async {
        let log = makeLog()
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
        let log = makeLog()
        log.clear()
        for i in 0..<50 { log.append("line-\(i)") }

        let lines = await log.recentLines(maxLines: 10)
        #expect(lines.count == 10, "上限件数を超えて返している: \(lines.count)")
        #expect(lines.last?.hasSuffix("line-49") == true, "最新ではなく先頭を残している")
        #expect(!lines.contains { $0.hasSuffix("line-0") }, "古い行が残っている")
    }

    @Test("空のログでは空配列（画面は「まだありません」を出せる）")
    func emptyLogReturnsEmpty() async {
        let log = makeLog()
        log.clear()
        // clear() はバージョン行を 1 行だけ残す仕様。行が積み上がっていないことを見る。
        let lines = await log.recentLines()
        #expect(lines.count <= 1)
    }

    /// ⚠️ **切り詰めが文字の途中で切っても、ログが空にならない**（2026-10-13 にテストで踏んだ）。
    ///
    /// 上限を超えたら末尾 `maxBytes` を**バイト数で**残していた。日本語（3 バイト）の行が多いと
    /// 切り口が文字の途中に落ち、ファイル全体が UTF-8 として読めなくなる——読み出しは
    /// `String(contentsOf:encoding: .utf8)` が失敗して**空**を返し、次に切り詰めるまで
    /// Developer Options のログ画面が空、ログを検査するテストが全部空振りした。
    /// 切り口を 3 通りずらして、どれかが必ず文字の途中に落ちるようにする。
    /// ⚠️ ずらすのは**末尾の行の長さ**（切り口は末尾から測る）。最初は先頭に詰め物をしていて、
    /// 切り口が 1 バイトも動かず、直す前の実装でも通った（ADR-268 の「実験が空振りする」形）。
    @Test("切り詰めの切り口が文字の途中でも、行が読める", arguments: [0, 1, 2])
    func trimKeepsUTF8Readable(padding: Int) async throws {
        let log = makeLog()
        let line = Data("あいうえお\n".utf8)   // 16 バイト（3 バイト × 5 ＋ 改行）
        var body = Data()
        while body.count <= log.maxBytes * 2 { body.append(line) }
        try body.write(to: log.fileURL)

        log.append("tail-marker" + String(repeating: "x", count: padding))   // ここで切り詰める
        // ⚠️ 全行を読む（既定の 3,000 行だと先頭＝切り口が見えず、行の途中から始まっても通った）。
        let lines = await log.recentLines(maxLines: .max)

        #expect(lines.last?.contains("tail-marker") == true, "切り詰めのあと読めない: \(lines.suffix(2))")
        #expect(lines.count > 1000, "切り詰めで行を失いすぎた（\(lines.count) 行）")
        #expect(lines.first == "あいうえお", "先頭が行の途中から始まっている: \(lines.first ?? "nil")")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int)
        #expect(size <= log.maxBytes, "切り詰めていない（\(size) バイト）")
    }

    /// 以前の切り詰めが作った傷（先頭が文字の途中）が残ったファイルも、空にせず読む。
    @Test("壊れたバイトが混じったファイルも、空にせず読む")
    func readsFileWithBrokenBytes() async throws {
        let log = makeLog()
        var body = Data(Array("あ".utf8).dropFirst())   // 文字の途中から始まる
        body.append(Data("\nalpha\nbeta\n".utf8))
        try body.write(to: log.fileURL)
        let lines = await log.recentLines()
        #expect(lines.suffix(2) == ["alpha", "beta"], "1 バイトの傷で全文を読めなくなった: \(lines)")
    }
}
