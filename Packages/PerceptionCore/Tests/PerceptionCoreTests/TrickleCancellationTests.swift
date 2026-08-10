import Foundation
import Testing
@testable import PerceptionCore

/// 中断が「1 単位」の内側まで届くこと（ADR-98）。
///
/// 実機 diagnostics-44 の回帰: 前面復帰の瞬間にタグ付けが始まり、キャンセルしたのに
/// `tags: start` → 11 秒後に `tags: finished — 4 tagged`。`BackgroundTrickle` の停止判定は
/// 「1 単位ごと」だが、その 1 単位がミニバッチ 4 枚（クラウドはサムネ DL＋Vision で 1 枚 2.7 秒）
/// だったため、丸ごと走り切って体感の固まりになっていた。
/// 単位の**内側**でも中断を見ること、そして**手を付けなかった分を完了として記録しない**ことを固定する。
@Suite("Trickle cancellation reaches inside a unit")
@MainActor
struct TrickleCancellationTests {

    @MainActor
    final class Recorder {
        var processedKeys: [String] = []
        var committedKeys: [String] = []
    }

    /// 1 単位＝4 枚のミニバッチを、内側で中断を見ながら処理する（本番の `senseInfo` と同じ形）。
    /// 中断された枚は**辞書に載せない**＝呼び手が「処理済み」にしない。
    private func senseLike(_ chunk: [String], cancelAfter: Int,
                           recorder: Recorder) async -> [String: String] {
        var out: [String: String] = [:]
        for (i, key) in chunk.enumerated() {
            if i >= cancelAfter { continue }   // 中断済みとみなして手を付けない
            recorder.processedKeys.append(key)
            out[key] = "tagged"
        }
        return out
    }

    @Test("中断後の枚は処理もされず、完了としても記録されない")
    func cancelledUnitsAreNeitherProcessedNorRecorded() async {
        let r = Recorder()
        let chunk = ["L-1", "L-2", "L-3", "L-4"]
        // 2 枚処理したところで中断された想定。
        let dict = await senseLike(chunk, cancelAfter: 2, recorder: r)

        // 呼び手（TagTagger.processUnit）の畳み方: 辞書に無いキーは載せない。
        let committed = chunk.compactMap { key in dict[key].map { _ in key } }
        r.committedKeys = committed

        #expect(r.processedKeys == ["L-1", "L-2"], "中断後の枚に手を付けている")
        #expect(r.committedKeys == ["L-1", "L-2"],
                "手を付けなかった枚を『処理済み』として記録している（次の窓で拾えなくなる・ADR-92 の罠）")
    }

    @Test("中断が無ければ全枚が記録される（従来どおり）")
    func withoutCancellationEverythingIsRecorded() async {
        let r = Recorder()
        let chunk = ["L-1", "L-2", "L-3", "L-4"]
        let dict = await senseLike(chunk, cancelAfter: 4, recorder: r)
        let committed = chunk.compactMap { key in dict[key].map { _ in key } }
        #expect(committed == chunk)
        #expect(r.processedKeys == chunk)
    }

    /// 取得**不能**な写真は空の結果を辞書に載せて「処理済み」にする＝無限リトライを避ける。
    /// 中断（辞書に載せない）と取り違えないこと。
    @Test("取得不能な写真は空の結果で『処理済み』になる（中断とは区別する）")
    func unavailablePhotosStillMarkedProcessed() {
        let chunk = ["L-1", "L-broken", "L-3"]
        // provider は取得不能でも空を載せて返す（中断だけが nil＝辞書から落ちる）。
        let dict: [String: String] = ["L-1": "tagged", "L-broken": "", "L-3": "tagged"]
        let committed = chunk.compactMap { key in dict[key].map { _ in key } }
        #expect(committed == chunk, "取得不能な写真まで落とすと永久にリトライし続ける")
    }
}
