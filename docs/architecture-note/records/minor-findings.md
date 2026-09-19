# 軽微な指摘（対応しないと判定したもの）

実在するが、**影響と頻度に照らして直すコストに見合わない**と判定した指摘。
影響が「利用者から観測できない」もの（見た目の粗・ログの誤り・内部の一貫性のみ）は、
たとえ毎回起きても対応しない——毎回ずれるログの件数表示は、利用者にとっては 0 回と同じ。

**ついで**の列が ○ のものは 1 ファイル数十行で直せる。その周辺を触る作業のときに
まとめて直してよい（そのためだけに着手はしない）。

## 2026-09-19 レビューループ（ADR-195〜199）

| 箇所 | 指摘 | 対応しない理由 | ついで |
|---|---|---|---|
| `SingleFlightTaskTests.staleCompletionDoesNotEmitFalse` | 世代ガードを外しても通る。新しい body が空なので、遅れてきた旧タスクより先に完走してしまい、旧タスクの末尾が `isRunning` の変化を起こさない | 同じ性質は隣の `staleTaskDoesNotClobberTheNewOne` が押さえており（そちらは新しい body を関門で止めるので効く）、守れていない性質は無い | ○ |
| `SingleFlightTaskTests.restartPreempts` | `order.contains("second")` しか見ないので、`restart` が `coalesce` と同じ（＝取り消さない）実装でも通る | 「明け渡させる」性質自体は `stopClearsPending` と `waitUntilIdle` 側で観測できる | ○ |
| `SingleFlightTaskTests.cancellationStillClearsTheFlag` | `stop()` が同期で旗を下ろすため、body が取り消しを観測しなくても通る | 旗の同期クリアは仕様どおりで、テスト名の性質（取り消し経路でも旗が残らない）は満たされている | ○ |
| `DebouncedTaskOverlapTests` の 40ms スリープ | 前提（body へ入っていること）を assert していなかった | 本ループで修正済み（`waitUntil` で前提を確かめる形にした） | — |
| `ShareImportPlanning.plan` の `Date(timeIntervalSince1970:)` | 有限性を自前で確かめず `decodeValidated` に依存する | 本番の呼び出し口は `ShareAnalysisFetch` 1 つで、必ず検証を通る。二重に検証するとどちらが正本か分からなくなる | ○ |
| `AnalysisCandidates` の空判定 | 共有の撮影日が索引に入ったことで `guard !index.isEmpty` が短絡しなくなり、空振りの detached スキャンが 1 回走る | 利用者から観測できない（件数 0 の走査） | ○ |

