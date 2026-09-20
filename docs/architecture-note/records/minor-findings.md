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
| レビュー中に落ちると、ためた編集通知が失われる | 13 周目で通知を「画面を閉じるとき 1 回」にまとめた。レビューを開いたまま jetsam されると `endPeopleReloadHold` が走らず、AI アルバムの掃除が起きない | 戻すと回答 1 回ごとに顔の台帳を全件引く（diagnostics-68 の再来）＝**確実な性能退行**。放置しても、次のドリフト検知の全再評価で掃除される（自己修復する）。稀な事象と確実な代償の交換にしない（レビュー 9 周目の教訓） | — |
| 情報パネルの「Person N」がピープル画面と違う番号 | `personNameByCluster` は `clusterID + 1`、ピープル画面は並び順の `displayIndex`。同じ人物が「Person 4985」と「Person 12」に見える | 揃えるには並び順の算出（`peopleClusters`）が要る。情報パネルの経路で毎回それを回すのは重く、規則を 2 か所に書くことにもなる。名前を付けていない人物にだけ起きる表示ゆれ | — |
| `fullyMatchedAll` が打ち切りで緩くなる | 1 回の取得に上限を付けたので、判定の対象が「変わった全部」から「取った 48 個まで」になった | 掃除は `cacheSettled`（同期が落ち着いている）でも守られており、掃除しすぎても rev が無いので取り直せる（自己修復する） | ○ |
| `SingleFlightTask.retiringLimit` の切り捨て | 控えが 4 本を超えると（5 本目を足す瞬間に）、**まだ走っている**いちばん古いハンドルを落とし得る | 5 本超えには `restart`/`stop` の連打が要る。本番の呼び出し方（スキャンの開始/停止）では到達しない | ○ |
| `AnalysisCandidates` の空判定 | 共有の撮影日が索引に入ったことで `guard !index.isEmpty` が短絡しなくなり、空振りの detached スキャンが 1 回走る | 利用者から観測できない（件数 0 の走査） | ○ |

