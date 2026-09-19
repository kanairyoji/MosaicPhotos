# 未解決の課題（直し方に設計判断が要る）

**実在する問題**だが、どう直すかの合意に至っていないもの。
素直な修正案は検討して退けてある（下の「退けた方向」）。片付けるには、
多くの場合コードの局所修正ではなく**設計上の選択**が要る。

片付いたら、この一覧から消して `decisions.md` / `case-studies.md` へ移すこと。

## 再評価中の編集結果が一覧から消える

- 箇所: `Packages/AutoAlbumCore/Sources/AutoAlbumCore/AIAlbum/AIAlbumService+Refresh.swift:96`
- 分類: staleUI / raceOnly / local / 優先度 P2
- 検討した回数: 1（初出 2026-09-03）
- 症状: 夜間のフル再評価中に前面へ戻って AI アルバムを編集すると、保存済みの編集内容が AI アルバム一覧から消えるか、編集前の表示へ戻る。再起動などでストアを読み直すまで表示と保存内容が食い違う。
- 解決と言える条件:
  - フル再評価中に編集されたアルバムは、再評価完了後の公開一覧に編集後のタイトル・条件・メンバーで存在する。
  - フル再評価中に削除されたアルバムは、再評価完了後の公開一覧へ復活しない。
  - 一部のアルバムが世代不一致で破棄された後に前面中断しても、返される一覧に欠落や重複がない。
  - 再評価済みで変更競合のなかったアルバムの結果は保持される。
- 退けた方向:
  - 台帳を最終返却値にする方向で、世代不一致時の欠落、件数ベースの再追加による重複、古い開始時スナップショットからの復活は解消できる。ただし、最終 `await loadAll()` の読み出し完了後から、呼び出し側が戻り値を公開状態へ代入するまでにも編集・削除が成立し得る。したがって、戻り値を台帳に一本化するだけでは条件1・2を完全には保証できない。最終読み出しと公開を同じ隔離領域で不可分にするか、refresh は評価結果だけを返し、公開側で現在の台帳・ID・世代と照合して競合のない結果だけをマージし、削除済みIDを再挿入しない設計に変更する必要がある。また「最終 loadAll 完了後、公開代入直前」に編集・削除を挟むテストを追加して保証すべきである。


## BackupKit のテストが 1 度だけ signal 11 で落ちた（再現せず・2026-09-18）
- 症状: `scripts/test.sh all` の中で `BackupKitPackageTests` が
  `exited with unexpected signal code 11`（SIGSEGV）。直後の単体再実行（281 テスト）と
  全体の再実行はどちらも通過し、**再現しない**。
- 状況: レビューループ中の実行で、同時に他パッケージのテストも走っていた。落ちたのは
  swift-testing のテストバンドル側で、失敗したテスト名は出ていない。
- 疑い: 並列実行下でのハーネスのクラッシュか、テスト内の競合（BackupKit は偽 Dropbox サーバと
  背景アップロードの並行テストを多く持つ）。後者なら**本番コードの競合を映している**可能性がある。
- 追記（同日 22:05）: **2 度目が別パッケージ（FaceCore）で発生**。どちらも
  `scripts/test.sh all`（複数パッケージを続けて回す）の最中で、単体での再実行は通る
  （FaceCore 247 テスト・BackupKit 281 テスト）。パッケージ固有ではなく、
  **並列実行下のハーネスか、テストが共有する何か**（一時ディレクトリ・インメモリ SwiftData の
  同時生成など）を疑う段階。2 時間で 2 回＝無視できない頻度。
- 次に見るとき: 落ちたら `~/Library/Logs/DiagnosticReports` の `*PackageTests*.ips` を拾い、
  クラッシュしたスレッドのフレームを見る（どのテストか特定できる）。
  `swift test --parallel` の有無で再現性が変わるかも見る。頻度が上がるようなら
  `-sanitize=thread` で回す。

## レビューループで未対応のまま残した 3 件（2026-09-18 22:15・次回の出発点）
> **更新（2026-09-18・ADR-195）**: 1 と 3 は修正済み（`refreshOnce`＝キャンセル時は旗を残す／
> 新鮮な列挙の抑制を時刻ベースに）。2 は**仕組みごと消えた**（ADR-195 でクールダウン・自動再開・
> 手動/自動の区別・画面の可視状態をすべて廃止）。残るのは末尾の「電池 20% 未満で手動タップが
> 始まってしまう」だけ（自動側が無くなったので非対称ではなく、単に「押す前に断るか」の設計判断）。

セッションウィンドウの都合で**記録のみ**にした指摘。9 周のあいだ「1 周あたり 3〜4 件の退行」が
続いていたので、レビューを受けられない時刻に未検証の変更を入れない判断をした（直る確率より
新しい穴が開く確率の方が高い、が 9 回続けて観測された事実）。

対象は最新コミット `d5a8c86`。3 件とも**同じ 2 ファイル**（`AnalysisSession` /
`AIAnalysisStatusView`）で、今日 9 周ずっと壊れ続けている領域。

1. **（中）キャンセル時に数え直しの要求を捨てている** — `AIAnalysisStatusView.refreshOnce` の
   `defer { refreshRequested = false; refreshRequestedFresh = false }` はキャンセル経路でも走る。
   ドレインループの持ち主は Section ごとの `.task` なので、スクロールでその Section が消えると
   ループが死に、直前に立った要求（解析完了の `onChange`）が誰にも処理されない。
   4 秒ポーリングは `isAnalyzing || session.isActive` が偽になった直後なので拾わない。
   → **完了直後の数字が凍る**（この機構が防ぐはずだった症状そのもの）。
   直し方の候補: `!Task.isCancelled` のときだけ旗を下ろす／抜ける前に要求を投げ直す。

2. **（中）クールダウンの免除に歯止めが無い** — `!(wasManual && statusScreenOpen)` の 2 つの入力が
   どちらも粘着質。`analysisSessionWasManual` は `markPending(false)`（＝完了か利用者の停止）
   まで残り、`statusScreenVisible` は `onDisappear` 起点なので**アプリを背面にしても false に
   ならない**。結果、状況画面を開いたままクラウド分が延々 `.deferred` になる状況では、
   Control Center・通知バナー・App スイッチャーのたびにフルセッションが立ち、
   8.5 万件の列挙とインジケータの点滅を繰り返す（クールダウンが防ぐはずだった churn）。
   直し方の候補: 免除は「明示のタップでクールダウンを解除する」（`start()` で実装済み）に限り、
   自動再開には免除を与えない。

3. **（低）新鮮な列挙の抑制が「交互」になっている** — `lastWasFresh = useFresh` だと、
   要求が 1 回おきに来る並びで 2・4・6 回目が毎回フル列挙になる。時刻ベース
   （候補キャッシュが数秒以内なら再利用）にすれば並び順に依存せず抑えられる。

**あわせて分かった既存の非対称**: 電池 20% 未満でも「今すぐ解析」の**手動タップは始まってしまい**、
`runLoop` が約 2 秒後に電池で止める＝インジケータが一瞬光る。自動再開側は手前で断つように
したが、手動側は素通り。押した人の意図を尊重するか、押す前に断って理由を出すかは設計判断。

## ADR-195 のレビューが出した 10 件（2026-09-18 23:00 → 2026-09-19 解消）
> **更新（2026-09-19・ADR-196）**: **10 件すべて対処済み**。上位 3 領域（背景ゲート網・
> 夜間窓スケジューラ・解析状況画面/ブースト）を 1 つの設計として直した結果、個別に直すのでは
> なく**発生源が消えた**形。対応: #1 一枚岩ゲート（`refreshIfNeeded` 全体を `.cloudMonolith` に）／
> #2・#7 駆動役の `alreadyRunning` と空振りバックオフ／#3 `.boostEnded` で `restartBackgroundFill`／
> #4 電池を表の行に（ブーストでも外れない）／#5 入口と譲りが同じ式／#6 `.blocked([Blocker])`／
> #8 `alreadyRunning` ＋ 候補キャッシュ＋バックオフ／#9 仕事が始まった起こしだけ台帳に書く／
> #10 `AnalysisDriverScaleTests`（回数で固定）。残りは末尾の「電池 20% 未満で手動タップが
> 始まってしまう」だけ——これも表の `lowBattery` 行が効くので、押しても 2 秒で止まる挙動は
> 変わらないが、「押す前に断って理由を出す」かは未着手。

`392e627` までを対象にレビューを 1 周回した結果。**今夜は修正しない**——上の 3 件と同じ理由
（レビューを受けられない時刻に未検証の変更を入れない）。重い順。★＝コードを読んで確認済み、
☆＝レビュワーの指摘のまま（未検証）。

1. **★（高）前面で一枚岩が動くようになってしまった（ADR-107 の退行）** —
   `AutoAlbumEngine.refreshIfNeeded` は `refinePlaceNames` を
   `monolithicHeavyWorkAllowed` の**外**で呼ぶ（AutoAlbumEngine.swift:350）。その中で地名が
   変わると `await generate()` を呼ぶ（同:404）。控えめ軸があった頃は前面で
   `heavyWorkAllowed` が偽だったので到達しなかったが、ADR-195 で前面アイドルでも真になる。
   HomeView の定期ティックは `!isAppInBackground` だけのゲートなので、充電＋20 秒放置で
   86k 件の台帳読み＋譲れない generate が前面で走る＝diagnostics-46 の固まりが戻る。
   → `refinePlaceNames` ごと `monolithicHeavyWorkAllowed` の内側へ移すのが素直。
2. **★（中）`.launch` / `.foreground` の起こしは production では必ず空振り** —
   `stopForForeground()` が `noteUserInteraction()` を呼ぶ（ADR-79・意図的）ので、
   `.active` 直後の `idleSeconds` は 0。`heavyWorkAllowedLocal` は 20 秒アイドルを要求するため
   `kick(.foreground)` は常に `.notAllowed`。`.launch` も `lastInteractionAt` が起動時刻なので同じ。
   **前面の生きた契機はアイドルティックだけ**で、2 つの契機は誤解を招くログを 1 行出すだけ。
   さらに通知バナー等の `.inactive`→`.active` のたびに `stopForForeground` が
   駆動役の前面作業を止め、再開まで「20 秒アイドル かつ 前回の kick から 120 秒」＝最大 2 分空く。
3. **☆（中）`.boostEnded` が両トリクルに対して no-op** — `stop()` が直前に
   `engine.stopBackgroundWork()` / `people.stopScan()` を呼ぶが `isTagging` / `isRunning` は
   実行中の 1 単位が解けるまで下りない。直後の `kick` は
   `bgfill: skip — already tagging/embedding` と `tagger.scan skip — isRunning=true` で空振りし、
   `lastKickAt` だけ立つ→次のアイドル起こしまで 120 秒死ぬ。
   → 窓の先頭と同じ `restartBackgroundFill()`（世代ガードつき）を使う／少し待ってから起こす。
4. **☆（中）`.lowBattery` で止めた直後に方針が同じ処理を再開する** — 電源ポリシー「常に」だと
   `backgroundAllowed()` が無条件に真で、電池の下限は `runLoop` の中にしか無い。
   「電池のため止めた」と表示しながら同じトリクルが 0% まで回り得る。
   → 電池の下限を方針側（`heavyWorkAllowedLocal` か `PowerStateMonitor`）へ移す。
5. **☆（中）`startScan` を通すゲートが、譲る側のゲートより緩い** — 入口は
   `heavyWorkAllowedLocal` だが、トリクルが譲るのは `heavyShouldPause()`＝これに加えて
   `HeavyLoad.isInFlight()` / `isGeneratingAlbums` / `isBrowsingPeople` を見る。起動直後の
   一括ロード中にアイドル起こしが来ると、75k 行の `scannedRefKeys()` を読んでから
   ゲート待ち→60 秒で 0 枚のまま畳む＝diagnostics-62/63 の「入口代だけ払う」形。
   → 入口の判定を `!heavyShouldPause()` に揃える。
6. **☆（中）残作業があるのに `.finished`（「すべて解析済みです」）と言い得る** —
   ADR-194 の台帳照会を外したので、顔スキャンが譲り待ちで畳んだ・回線 NG でクラウドを
   対象外にした場合も「終わった」と表示し `setTaskCompleted(success: true)` を返す。
   コード中の「早めに `.finished` でも失うものは無い」は、方針が実際に続けられる場合だけ成り立つ。
7. **☆（低）空振りでも `lastKickAt` を立てる／`kicking` 中の契機を捨てる** — ゲート待ちで
   60 秒後に畳んだ直後に条件が開いても、次の評価は 120 秒後。候補列挙中に来た
   `.power` / `.network` / `.boostEnded` は `guard !kicking` でログも残さず消える。
8. **☆（低）毎回のアイドル起こしが規模比例の前口上を丸ごと繰り返す** — 残作業の有無を見ないので、
   充電中に開きっぱなしだと 1 時間に約 30 回、`enrichedRefKeysNewestFirst()`（86k）と
   `scannedRefKeys()`（75k）を読む。CLAUDE.md の「無いものを繰り返し探さない」に反する。
   → 安い残作業カウントで門を作る／空振り後はバックオフし `.power` 等で解除。
9. **☆（低）`RunTimeline` に 120 秒ごとの行を書いている** — この台帳は「1 日に数十行」の前提で
   256KB を数か月ぶん保つ設計（diagnostics-81 の教訓）。実際に仕事をした起こしだけ記録する。
10. **☆（低）ADR-119 の規模テストが無い** — `AnalysisDriverPolicyTests` は enum の判断しか見ない。
    「空の残作業で N 回アイドル起こし → 全件 fetch は高々 1 回」を `PerfTrace.takeCounts()` で
    数える回帰テストが要る。

**あわせて掃除するもの**: 廃止した「控えめ」「4 軸」「60 秒アイドル」を指すコメントが
`BackgroundYield.swift:74-76,109` / `MosaicPhotosApp.swift:15` / `TouchActivityTracker.swift:5` /
`HeavyWorkScheduler.swift:13` / `AutoAlbumEngine.swift:333` に残る。
`HeavyWorkTimingTests` のテスト名も「控えめ ON/OFF」のまま（本文は見ていない）。
`AnalysisSession.runLoop` は駆動役と同じ候補列挙・prune・startScan を重複して持ち、
駆動役の 10 分キャッシュを迂回している。
