# 事例・バグ・大きめの課題対応 — マスター

> このファイルが**事例（バグ・性能課題・大きな対応）の正本（マスター）**です。HTML（`docs/architecture-note/case-studies/`）は、ここから必要なものを選んで詳述した派生物であり、全件を転記するとは限りません。
>
> **運用ルール**
> - 埋め込んだバグ、原因が非自明だった不具合、性能・メモリ・起動などの大きめの課題対応をしたら、必ずこのファイルに 1 項追記する（網羅）。
> - HTML へ詳細ページを作るかは別途指示で決める（取捨選択）。
> - フォーマット: `## タイトル` ＋ **症状 / 原因 / 対処 / 関連（コミット・ファイル） / 残課題**。
> - 「軽微な修正」は省いてよいが、「同じ罠に再びはまりそうなもの」は必ず残す。

## テンプレート

```
## タイトル
- 症状: 観測された事象。
- 原因: 真因（表面ではなく根本）。
- 対処: 何をどう直したか。
- 関連: コミット / 主なファイル。
- 残課題: あれば。
```

---

## AI アルバム編集後にアプリが数十秒固まる（メインスレッドの飢餓・diagnostics-48）
- 症状: AI アルバムの編集（更新）後、および直後の操作全般で完全なフリーズ
  （実測: メイン 20.5 秒・9.4 秒・10 秒級 × 6 回連続）。「閉じる」でも固まって見える。
- 原因: **メインスレッドは何も実行していないのに、CPU を高優先度の協調タスクに奪われて
  スケジュールされない「飢餓」**だった（占有ではない。ModelActor がメインで走る仮説は
  macOS 検証テストで棄却）。重なった要因は 3 つ:
  (1) `beginMakeAIAlbum` に二重実行ガードが無く、連打で同一 make が 2 本並走
  （86k フェッチが actor 上で直列化され fetch 20.7 秒 × 2）。
  (2) make/FM 推論が `.userInitiated`＝P コアを占有する優先度で走っていた。
  (3) 解釈器 v7 移行の全再解釈（stale ドリフト）が背面窓で始まり前面復帰後も継続、
  さらに**アルバムごとに** 86k フェッチ＋カタログ構築を繰り返していた（約 10 秒 × 5 本）。
- 対処: (1) `isMakingAIAlbum` ガードで二重実行を抑止。(2) make・FM 推論（解釈/プローブ/翻訳）を
  `.utility` へ（スピナーがあるので応答性優先）。(3) refresh はカタログ/全メタをループ外で
  1 回だけ構築して `interpretation(baseLite:prebuiltCatalog:)` で共有し、**前面復帰したら
  アルバム間で中断**（残りは次の夜間窓の stale 判定が続きをやる）。
- 関連: diagnostics-48 / `AutoAlbumEngine+Recognition.swift` / `AIAlbumService.swift` /
  `AIAlbumInterpreter.swift` / `FoundationModelsQueryUnderstanding.swift`。ADR-107（一枚岩の
  非アクティブ限定）・ADR-99（段別計測——ただし本件でスパン値は「メイン復帰待ち」で
  膨らむことが判明。スパン＝実処理時間と読まないこと）。
- 残課題: 人物レビュー回答ごとの一覧再発行ハング（0.6〜0.7 秒・ADR-95 の債務）。
  MetricKit の HANG-DIAG はまだ未着（次ログで確認）。

## コンポーザの件数プレビューが「綺麗な写真→0 枚」になっていた（fail-closed の取りこぼし）
- 症状: AI アルバム作成画面で「綺麗な写真」「笑っている写真」「2人の写真」等を入力すると、
  ヒット件数プレビューが常に 0 枚と表示される（アルバム自体は正しく作られる）。
- 原因: S10/S12 で足した属性条件（`.beautiful` / `.smiling` / `.peopleExactly`）は
  **実測シグナル（美的スコア・笑顔・人数）が無いと fail-closed**（証拠が無ければ落とす＝
  ADR-103 の設計どおり）。本番検索（rankedSearch）は `querySignalsIfNeeded` でシグナルを
  引いてから評価するが、コンポーザの件数プレビュー（`groundingPreview`）は**シグナル無しの
  `hardFilter`** を呼んでいた。条件を足したとき、同じ評価器を使う**別の呼び出し元**への
  伝播を見落とした形。
- 対処: `querySignalsIfNeeded` を internal に開き、プレビューでも本番と同じシグナルを
  取得して渡す（取得は ModelActor 上・件数計算は detached＝メインは塞がない）。
- 関連: `AutoAlbumEngine+Suggestions.swift`（groundingPreview）/ `AIAlbumService.swift`。
  ADR-103（fail-closed の原則）。
- 残課題: シグナル辞書（86k 件）をキー入力（デバウンス後）ごとに引き直している。体感で
  問題が出たらコンポーザ表示中のキャッシュを検討。

## 眠っているタスクが「実行中」フラグを握り、夜間の窓を丸ごと空転させていた（diagnostics-38）
- 症状: 実機ログで 5 つの症状が同時に出た。(a) フォアグラウンドのハング **105 回**（最大 3490ms）、
  (b) VLM キャプションが**ゼロ**（`caption window ... pending=796` は出たのに 1 枚も生成されない）、
  (c) 埋め込みが 40181 件滞留したまま `embed: finished — 0 photos in 0.0s`、
  (d) 起動直後に 2.8s / 3.5s のハング、(e) BGTask 窓 77 秒が完全に空転。
- 原因: 別々に見えた症状のうち (b)(c)(e) は**同じ真因**だった。前面起動で始まった `bgfill` が
  ゲート閉（控えめ設定＋前面）で `waitWhilePaused` に入り、**実行中フラグ `isTagging` を
  14 分間握ったまま眠っていた**（14 分でタグ 208 枚＝ほぼ眠っていた）。その間に開いた
  夜間 BGTask 窓もキャプション窓も `bgfill: skip — already tagging/embedding` で捨てられた。
  「ゲートが開けば自分で再開するから待てばよい」という設計だったが、**待つ側が資源（フラグ）を
  握っている**点を見落としていた。(c) は加えてフェーズの切れ目で `Task.isCancelled` を見ておらず、
  前面復帰でキャンセル済みのタスクが次フェーズへ進んで「40181 件やります」と嘘のログを出していた。
  (a) は人物リストの再発行が 2 秒に 1 回（顔スキャンのバッチごと＋レビューの回答ごと）走り、
  1 回ごとにメインが 600〜1000ms 止まっていた（分あたりのハング数と発行回数が完全一致）。
  `PersonInfo` が全メンバーキーを積んでいたため 1 回あたりのコストも大きく、
  `PersonAlbumView.init`（SwiftUI は再評価のたびに呼ぶ）が毎回それを decode し直していた。
  (d) は変化のないポーリングでも 68,200 行を fetch して署名を比べ、大半を捨てていた。
- 対処: [[ADR-95]]。譲り待ちに上限（60 秒）を設けて超えたら実行を畳みフラグを解放する。
  BGTask 窓の先頭では滞留した実行を明け渡させる（`restartBackgroundFill`・世代ガード付き）。
  キャプション窓では実行中の顔スキャンも止め、その回だけキャプションを先頭に回す。
  フェーズ間で `Task.isCancelled` を見る。人物一覧はメンバーキーを積まず・同じなら代入せず・
  連続変更は 700ms 静止までまとめる。Dropbox キャッシュに変更リビジョンを持たせ、
  変わっていなければ fetch しない。
- 関連: `BackgroundTrickle` / `AutoAlbumEngine+Recognition` / `PeopleEngine` / `FaceStore+People`
  / `DropboxCacheStore` / `DropboxPhotoStore` / `HeavyWorkScheduler` / `PersonAlbumView`。
- 検証（diagnostics-39・修正後ビルド）: ハング 105 → 9 回、人物リスト発行 101 → 2 回、
  `cachedItems()` 起動 3 秒で 2 回 → 17 分で 2 回。`bgfill: cancelled after tag phase` が
  正しく出るようになり、嘘のログは消えた。残り 9 回は (1) ゲート閉のまま準備だけ走る
  （`bgfill: begin (pause=true)` → 5〜8 秒後に `tags: start` → `0 tagged`）と
  (2) 起動直後の `loadItems()` 多重実行（`items.isEmpty` ガードを全員がすり抜ける
  check-then-act の競合）で、いずれも同一コミットで修正。
- 検証2（diagnostics-40）: **キャプション生成を確認**（`bgfill: captions 12 done (pending 796→784)`）。
  BGTask 窓は 4 分 45 秒で完走（`bgtask: end (completed)`）、窓の中でキャプションが埋め込みより
  先に回った。レビュー連続回答 19 回でハング 0。
- 残課題: **止めたつもりが止まっていなかった**（別記）。クラウド顔埋め込みの歩留まりは依然サンプル不足。

## 復帰直後の固まり — 今度は本物だった（diagnostics-44）
- 症状: 実フィードバック「他のアプリを使って戻ったときに固まる」。34 分のログでハングは 2 件
  （大幅減）だが、復帰直後の 1 件が 10469ms。前回（[[ADR-97]]）の偽ハングと違い、
  **実作業を伴っていた**: `tags: start` → 11 秒後に `tags: finished — 4 tagged`、
  `tags.photoMs=1(Σ2665.8ms)`、サムネのバッチ取得 3 本（817/1021/939ms）。
- 原因: 復帰の瞬間に `bgfill` のタグ付けが始まり、`stopForForeground()` でキャンセルしたのに
  11 秒走り切った。`BackgroundTrickle` の停止判定は「1 単位ごと」だが、**その 1 単位が
  ミニバッチ 4 枚**で、クラウド写真だと 1 枚 2.7 秒（サムネ DL＋Vision）＝1 単位 11 秒。
  単位の内側に中断点が無かった。
- 対処: 単位の内側（1 枚ごと／推論の直前）で `Task.isCancelled` を見る。中断した写真は
  結果に載せない（載せると「処理済み」として保存され次の窓で拾われない＝[[ADR-92]] の罠）。
  取得不能な写真は従来どおり空を載せる。[[ADR-98]]。
- 関連: `VisionTagAdapter.senseInfo` / `AIPerceptionAdapters.perceive` / `TagTagger` / `PhotoTagger`。
- 教訓: **最適化が別の不変条件を壊していた**。ミニバッチ化（ANE 償却・[[ADR-83]]）は
  スループットのための正しい変更だったが、「1 単位ごとに譲る」という応答性の前提を
  黙って壊していた。粒度を変えたら、その粒度に依存している別の性質を洗い直す。

## 4 回追いかけた「復帰直後の 10 秒ハング」は、実在しなかった（diagnostics-43）
- 症状: diagnostics-40〜43 のいずれでも、フォアグラウンド復帰の直後に 9〜11 秒の
  `hang main=...(foreground)` が記録された。毎回いちばん大きな数字なので、毎回原因を追った。
- 原因: **計測の汚染**だった。diagnostics-43 で決着した——このログでは重い処理が
  **一つも走っていない**のに `hang main=11041ms` が出た。
  `labeler: prewarm cancelled at 0/314`（0 語で中断）、`model load skipped (cancelled) — face model` ×4、
  `faces.detect: ... load=0ms infer=0ms`。直前の修正が全部効いて何もしていないのに、数字だけ残った。
  `MainThreadWatchdog.record` は「**返答時**に前面か」しか見ておらず、背面で送った ping が
  復帰の瞬間に返ると前面ハングとして計上される。`ProcessSuspension` は正式な中断しか捉えられず
  復帰前後の throttle はすり抜ける——この制約はコードのコメントに**既に書いてあった**のに、
  判定条件には反映されていなかった。
- 対処: 前面へ復帰した時刻を持ち、それより前に送られた ping は前面ハングに数えない
  （`bgStalls` には残す）。`hang.begin` にも同じ判定。[[ADR-97]]。
- 関連: `MosaicSupport/MainThreadWatchdog.swift`。[[ADR-82]]（背面/前面の分離の初出）。
- 教訓: **一番大きい数字から追う**のは正しいが、その数字が本物かを先に確かめる。
  今回は「修正が全部効いて作業ゼロなのに数字が変わらない」ことが決め手になった——
  **対策を入れても数字が動かないときは、対策ではなく計測を疑う**。
  センサーの既知の制約をコメントに書くだけでは足りず、判定条件に落とす必要がある。

## 人物一覧の再読込が 936 回のクエリだった — 計測を入れて初めて分かった（diagnostics-42）
- 症状: レビューを連続回答している間、1 回答ごとにフォアグラウンドが 540〜645ms 固まる。
  ADR-95 で「発行回数」も「メンバーキーの持ち回り」も削った後も残っていた。
- 原因: 3 度の実機ログで機序を推測しては外していたため、**推測をやめて段ごとの計測**
  （`people.load.tuning` / `.favorites` / `.clusters`）を入れた。次のログ（diagnostics-42）で即決着:
  `people.load.clusters` が 725〜3585ms で、**同じ長さのハングと 1 対 1 に対応**していた
  （671/725・896/997・2028/2188）。`peopleClusters` はクラスタごとに `faces(inCluster:)` を
  呼ぶ N+1 クエリで、936 クラスタなら 936 回の fetch。しかも表示に一切使わない
  `DetectedFace.embedding`（512 次元・約1KB/顔）まで毎回 materialize していた。
- 対処: 全顔を **1 回の射影クエリ**（`propertiesToFetch` で `embedding` を除外）で取り、
  クラスタ ID でメモリ上に束ねる。`peopleEligibleClusters` も同様に射影する。[[ADR-96]]。
- 関連: `FaceCore/Faces/FaceStore+People.swift`。[[ADR-88]]（同じ射影を別メソッドに入れた先例）。
- 教訓: **同じ罠を別メソッドに残していた**。ADR-88 で「全カラム materialize が 1.2〜1.4 秒の
  フリーズを生む」と特定して `memberRefKeys(inCluster:)` を射影化したのに、**人物一覧の本体**は
  素のままだった。1 か所直したら、同じ形が他にないか横に探す。
  もう一つ: 3 回外したら推測をやめて計測を入れる。入れた次のログで一発で決まった。

## 「止めた」が伝わらない — 事前ウォームの cancel が共有 Task に届いていなかった（diagnostics-40）
- 症状: フォアグラウンド復帰の直後にメインが 11.6 秒ブロック。同時刻に
  `model loading… CLIP text tower` → `CLIP text tower loaded in 15456ms`、footprint 526MB。
  復帰時には `stopBackgroundWork()` が走っており、設計上は事前ウォームを止めているはずだった。
- 原因: `stopBackgroundWork()` は `prewarmTask?.cancel()` を呼ぶが、表示ラベラ
  （`CLIPDisplayLabeler`）の `ensureEmbeddings()` は**二重構築を防ぐため共有の `buildTask` に
  合流**する作りで、`await task.value` しているだけ。**別の unstructured Task へは cancel が
  伝播しない**。加えて約300語のループに `Task.isCancelled` の確認が無く、いったん始まると
  CLIP テキストタワーのロード（15.5 秒）ごと走り切って ANE ゲートを占有し続けていた。
- 対処: seam に `LabelProvider.cancelPrewarm()`（既定 no-op）を新設し、共有 Task を直接 cancel する。
  ループは 1 語ごとに中断を見て、途中結果は確定させない（`isReady` は false のまま＝
  フル画像 insight は Vision タグだけで即返るので表示は壊れない）。
  併せて ANE ゲートの 1 秒以上の待ちを `ANE gate: waited Nms` として記録する。
- 関連: `AutoAlbumCore/Perception/Providers.swift` / `MobileCLIPKit/CLIPDisplayLabeler.swift`
  / `AutoAlbumCore/AIAlbum/AutoAlbumEngine+Recognition.swift` / `PerceptionCore/MLInferenceGate.swift`。
  テスト: `LabelProviderPrewarmTests`。
- 続き（diagnostics-41 で同型を再確認・より明確な証拠）: 今度は**顔モデル**で同じ形が出た。
  `09:51:09 faces: stopScan (foreground return)` の**1 秒後**に `09:51:10 model loading… face model`、
  そして `face model loaded in 10883ms`／`faces.detect: ... infer=11667ms`、同時刻にメインが
  10.5 秒ブロック。**止めた直後に、最も高価な操作（10 秒級のモデルロード）を始めていた**。
  原因は `BackgroundTrickle` が単位の**前**にしかキャンセルを見ないこと＝いったん `processUnit` に
  入ると、その中で始まる遅延ロードは止まらない。
  対処: `CoreMLModelLoader.skipLoadWhenCancelled(isLoaded:subject:)` を新設し、4 つの重いモデル
  （顔・CLIP テキスト塔・CLIP 画像塔）の遅延ロード入口で「キャンセル済みかつ未ロードなら**始めない**」。
  ⚠️ 判定は `LoadOnce` の**外**で行う——中で nil を返すと `.some(nil)`＝「失敗・再試行しない」として
  恒久キャッシュされ、その機能が二度と有効にならない。併せて、中断された 1 枚は結果に載せない
  （[[ADR-92]] と同じ理由＝「走査済み」として記録されると次の窓で拾われなくなる）。
- 教訓: **「cancel を呼んだ」は「止まった」ではない**。`await someTask.value` で合流する設計では
  cancel は伝播しない。止める意思は**合流先まで届く経路**（seam のメソッド・中断点）で表現する。
  [[ADR-95]] の「待つ側が資源を握らない」と対で、「止めた側の意思が実際に効いているか」を
  ログで確認できるようにしておく。
  クラウド顔埋め込みの歩留まりは本ログでも 59 枚しか走っておらず（30/87=34.5%）、
  [[ADR-90]]（1024px + 80px）の評価には依然サンプル不足。
- 教訓: **待つ側が資源を握らない**。「ゲートが開けば自分で再開する」設計は、待っている間に
  握っている排他フラグ・モデル・メモリが**他の実行機会を殺していないか**まで見て初めて成立する。
  飢餓バグ（[[ADR-72]] バックアップ、[[ADR-85]] 埋め込み、[[ADR-86]] キャプション）は
  これで 4 度目だが、今回は「順番を回す」ではなく「待機が排他を伴わない」形に直した。

## 通信と計算を重ねる発想が抜けていた（クラウド解析・指摘されるまで気づかず）
- 症状: AI 解析の高速化で「クラウドサムネをバッチでまとめて取る」対策を入れたが、
  **バッチの先頭で毎回ダウンロード待ちが露出**したままだった（バッチ間が重ならない）。
  ユーザーから「通信と処理を並行させるのはプログラミングの基本では」と指摘されて判明。
- 原因: 対策を「往復を減らす（バッチ化）」だけで考え、**「待ち時間に別の仕事をする」
  （パイプライン化）**を検討していなかった。実測で「DL が 85〜90%」と分かった時点で、
  バッチ化と先読みの両方が導かれるはずだった。
- 対処: 各タガーが `nextBatch` の中で**次バッチ分**も `warmUp` する（ADR-83 追記）。
  推論は ANE ゲートで直列＝1 バッチ約 1.6 秒、その裏で次バッチの DL（約 0.8 秒）が
  完全に隠れる。ダウンロードは URLSession＝ANE ゲート対象外なので真に並行する。
- 関連: `FaceTagger` / `TagTagger` / `PhotoTagger` の `nextBatch`。[[ADR-83]]。
- **再発防止**: `CLAUDE.md` の「性能設計の既定原則」に、実測 → (1) I/O と計算を重ねる
  (2) 往復をまとめる (3) 不在も覚える (4) 巨大コレクションを MainActor に通さない
  (5) 計測が体感を表すか確かめる、をチェックリストとして明記した。
- 教訓: 遅さの対策は「**1 単位を速くする**」と「**待ちを埋める**」の 2 軸で考える。
  実測で I/O 支配と分かったら、後者を必ず検討する。

## 「ハング 39 件・最大 28.5 秒」の 8 割は背面の計測ノイズだった
- 症状: 復帰時の対策（ADR-79/80）後も実機ログに 39 件のハングが残り、最大 28.5 秒。
  一見すると対策が効いていないように見えた。
- 原因: **前面と背面が混ざっていた**。分類すると 31 件（最大 28.5 秒）はアプリが**背面**に
  いる間のもの。iOS は背面でメインランループを絞る／必要なら中断するため、ping が途切れて
  「メインが 28 秒ブロック」と記録されるが、**ユーザーには一切見えない**。
  `ProcessSuspension`（既存の中断検出）は**正式な中断**しか捉えられず、単なる throttle は
  素通しだった。前面の実力は最大 3.2 秒で、実際には大きく改善していた。
- 対処: ADR-82。`MainThreadWatchdog` に前面/背面の状態を持たせ（`BackgroundYield.isAppActive`
  の `didSet` から自動同期＝伝え忘れが構造的に起きない）、背面サンプルは `pings/max` に混ぜず
  `bgStalls=N` として別枠に。即時ログも前面のみ・`(foreground)` を明示。
- 関連: `MainThreadWatchdog` / `BackgroundYield.isAppActive`。
- 教訓: **計測が信用できないと対策が的を外す**。実際、私も最初この 31 件を体感の悪化と読み違えた。
  センサーには「その値が体感に効く文脈か」を持たせ、文脈外の値は別枠にする（消さない）。

## 起動のたびに「存在しないバックアップメタデータ」を探しに行っていた
- 症状: 起動のたびに `net.get_metadata ... status=409` が 4 回、うち 2 回は 2.8〜3.3 秒。
- 原因: バックアップ未使用のユーザーは v1 `metadata.json` とカタログの計 4 パスがどれも存在せず、
  毎起動 409 が返るまで待っていた。rev キャッシュ（ADR-38）は「**あるファイル**の再取得」を
  避ける仕組みで、「**無いファイル**を探しに行く」ことは避けられない設計だった。
- 対処: ADR-82。不在を記録して TTL(24h) 内は問い合わせない（`BackupMetadataAbsence`）。
  無効化は明示更新（バックアップ画面）とバックアップのメタデータ書き込み直後の 2 経路。
- 関連: `BackupMetadataAbsence` / `DropboxPhotoStore+BackupMetadata` / `BackupRunner`。
- 教訓: キャッシュは「ヒット」だけでなく「**不在**」も覚える価値がある（negative caching）。
  ただし無効化経路を必ずセットで用意すること——今回は「バックアップ書き込み直後」を入れ忘れると
  初回バックアップ後 24 時間バッジが出ない、という別のバグになるところだった。

## 解析候補の並べ替えが起動のたびにメインを 3 秒止めていた
- 症状: 起動直後に 2.7〜3.2 秒のメインハングが毎回 2 回。
- 原因: `analysisOrderedRefKeys` が `@MainActor` で、`cloudImageRefKeys`（6.8 万件のソート＋map）と
  `AnalysisOrder.ordered`（8.6 万件のソート・比較ごとに接頭辞判定と Set 参照）を**メインで**実行
  していた。オフメイン化した個別処理（PHAsset 列挙など）はあったが、**最後の合成と並べ替えが
  メインに残っていた**。
- 対処: `dropboxStore.items` のスナップショット（COW＝取得は安価）を渡し、合成・並べ替え全体を
  `Task.detached` へ。夜間 BGTask も同じ経路なので背面の長い停止も軽くなる。
- 関連: `PeopleSupport.analysisOrderedRefKeys`。[[ADR-82]]。
- 教訓: 「重い部分は detached にした」で安心しない。**呼び出しチェーンの末端（合成・ソート）**が
  MainActor に残っていないか、@MainActor 関数の中身を最後まで見る。

## 他アプリから戻ると固まる（夜間処理は「譲る」だけで止まっていなかった）
- 症状: 他アプリを使って戻ってくると、数秒〜数十秒アプリが固まることがある（毎回ではない）。
- 原因: 復帰時に夜間処理（BGTask ルーチン）が**生きたまま**だった。ゲート（`BackgroundYield`）は
  閉じるが、それは各トリクルを `waitWhilePaused` で眠らせるだけで、(1) 実行中の 1 単位は完走する
  （VLM キャプションは 1 枚数十秒＝ANE/CPU 飽和）、(2) 眠っている間も VLM≈877MB を抱え続けて
  メモリ圧迫の連鎖を招く、(3) `generate` は単位分割が無く 18 秒超・最大 880MB を走り切る。
  アプリ切替時に `HeavyWorkScheduler.submit()` で予約されるため、**充電中に切り替えたときだけ**
  BG 窓が開いて症状が出る＝再現が不安定に見えた。
- 対処: ADR-79（復帰時は cancel・譲り開始で VLM 解放・generate に中断点・86k 取得を off-main・
  scenePhase 実測ログ）。
- 関連: `HeavyWorkScheduler` / `MosaicPhotosApp` / `AutoAlbumEngine` / `PeopleEngine` / `BackgroundTrickle`。
- 残課題: 実行中 1 単位ぶんの遅延（VLM 1 枚）は残る。気になるなら VLM のバッチ単位をさらに割る。
- 教訓: 「重い処理を止める」設計で **fire-and-forget の Task は cancel が伝播しない**。
  起こした側が停止 API を持つこと。また「ゲートで譲る」は CPU は返せてもメモリは返せない。
- **続報（diagnostics-31）**: 上記対応後もカクつきが残り、ログで**真因は BGTask ではなく前面の
  定期ループ**と判明した。決め手は「`bgtask: begin` が復帰前後に 1 件も無いのに
  `[Engine] generate: begin` が `scene: active` の直後に出ている」こと。
  - **アイドル判定が復帰を無視していた**: `idleSeconds` は最終タッチからの経過なので、戻った
    瞬間は「20 秒以上アイドル」＝重い処理を始めてよい、と判定される。結果、復帰と同時に
    generate が 22.8 秒走り、メインを 2.4s/1.7s/5.9s/3.9s ブロックしていた。
  - **地名補正が毎ティック 86k 件を読んでいた**（ADR-76 の実装漏れ）: 単独で `hang main=10581ms`。
    署名（写真件数＋補正世代）で空振りを弾いて解消。
  - 教訓 2: **「アプリに戻ってきた」はユーザー操作である**。アイドル計測を持つなら、
    フォアグラウンド復帰でリセットしないと「離席中の蓄積」がそのまま復帰直後に牙を剥く。
  - 教訓 3: 定期ティックから呼ぶ処理に**全件スキャンを足すときは空振り判定とセット**にする。

## クラウドお気に入りが統合ビュー（All Photos）だけ丸ごと無効だった（機能追加時の追随漏れ）
- 症状: 「クラウドのサムネイルにハートが出ない」を 1 度修正した（下記の別項）後も、
  **All Photos タブだけ**クラウド写真のハートが出ず、そもそも付け外しもできない。
- 原因: `MergedPhotoItem.isFavorite` / `supportsFavorite` と `MergedPhotoStore.setFavorite` が
  **cloud を常に false** にしていた（コメントも「Dropbox にはお気に入りの概念がない」）。
  これは ADR-67 で **アプリ側クラウドお気に入り**（`cloudFavoritePaths`）を実装する前の事実で、
  実装時に `DropboxPhotoStore` 側だけ対応し、**統合層へ追随していなかった**。
  Cloud タブは `DropboxPhotoStore` を直接使うため動いており、統合ビューだけ壊れていた＝
  「片方の入口では動く」ため発見が遅れた。
- 対処: 3 箇所を内包要素への委譲に変更。`setFavorite` は成功時に該当 1 件だけ刻印し直す
  （`rebuildItems()` は 68k 件の再ソートなので 1 件のトグルでは呼ばない）。回帰テストを追加。
- 関連: `MergedPhotoItem` / `MergedPhotoStore.setFavorite`。[[ADR-67]]（クラウドお気に入り）。
- 教訓: **同じ機能に入口が複数ある**（Cloud タブ / All Photos）とき、片方だけ直すと
  もう片方が静かに取り残される。値型の委譲（`case .cloud: return false` のような固定値）は
  機能追加時に見落としやすいので、追加時は「この型を包む上位の型」も必ず grep する。

## クラウドお気に入りのハートがグリッドに出ない（構成不変の更新で items が差し替わらない）
- 症状: Dropbox ビューでお気に入りを付けても、サムネイルグリッドにハートが出ない
  （ローカルは出るように見える）。ストア側（`DropboxPhotoStore+Favorites`）は items へ即刻印している。
- 原因: `PhotoCollectionView.update()` は「枚数・グルーピング・先頭/末尾 ID」のシグネチャが同じなら
  snapshot 再構築を丸ごとスキップする（68k の再構築を避ける perf 対策）。お気に入りの付け外しは
  **ID 列が不変で isFavorite だけ変わる**ためスキップに落ち、`self.items` も差し替わらず
  可視セルも再構成されない＝新しい値がどこにも届かない。ローカルは `LocalPhotoItem.isFavorite` が
  PHAsset を直接読む（生きた参照）ため偶然表示されていた。
- 対処: シグネチャ一致時も items の参照は差し替え（COW・O(1)）、**可視セルのお気に入り差分が
  あるときだけ** `reconfigureItems` する（`refreshVisibleFavoritesIfChanged`）。snapshot 再構築はしない。
- 関連: `PhotoCollectionView.update/refreshVisibleFavoritesIfChanged` / `DropboxPhotoStore+Favorites`。
- 教訓: 差分スキップの「シグネチャ」に含めていない属性は、変わっても画面に届かない。
  スキップ経路にも「軽い内容更新」の枝を用意する。

## Apple の地名補正が既存写真に届かなかった（台帳の placeName は enrich 時に固定される）
- 症状: 「時間と場所」の地名がいつまでもオフライン都市 DB の粗い名前のまま（隣の大都市名に丸まる）。
  夜間の CLGeocoder 補正（ADR-68）は実装済み・成功しているのに、トリップ名も訪問地も変わらない。
- 原因: 2 つの独立した欠陥の複合。
  1. **補正の対象がトリップ代表座標（メンバー座標の単純平均）だけ**。複数都市の旅行では平均が
     「誰も撮っていない地点」になり、補正しても写真の属するセルは 1 つも refined にならない。
  2. **補正結果が台帳へ伝播しない**。`EnrichedPhoto.placeName` はエンリッチ時に 1 回だけ解決して
     `PhotoEnrichment` に永続化され、以後スキップされる。補正後に `generate()` を呼び直しても、
     トリップ名は**台帳に保存済みの古い placeName** から組み立てるため変わらない（新規写真にしか効かない）。
- 対処: ADR-76（補正対象を「写真のあるセル」へ・台帳伝播・オフライン距離格下げ）。
- 関連: `AutoAlbumEngine.refinePlaceNames` / `PhotoEnricher` / `TimePlaceStrategy.makeDraft` / `PlaceRefinement`。
- 残課題: なし（伝播は毎晩の差分突き合わせで自己修復）。
- 教訓: 「解決結果をキャッシュから台帳へコピーして持つ」設計は、キャッシュ側だけ更新しても表示が
  変わらない。台帳へ写した値には**追随の経路**（差分伝播 or 参照時解決）を必ず用意する。

## 実機ログの所要値が壁時計で汚染されていた（「メインが 29 分ブロック」の正体はプロセス中断）
- 症状: 実機ログ（diagnostics-20・4 時間）に `PERF hang main=1764917ms`（**29.4 分**）が出る。
  `faces.detect` の `load=` 合計 1,868,367ms のうち **1,769,333ms が単一の外れ値**（中央値は 81ms）。
  `face.photoMs=1(Σ492753.8ms)`、`embed: batch … in 1866.7s` も同様。
- 原因: **バックグラウンドでの OS によるプロセス中断（suspend）**。計測に使う時計は中断中も進む
  （`CFAbsoluteTimeGetCurrent` は壁時計、`DispatchTime.uptimeNanoseconds` も端末が起きていれば進む）。
  該当箇所を追うと `10:22:38 main: idle` → `10:51:48` の空白がそのまま「ハング」として記録されていた。
  **背景実行を診断するために作った仕組みが、背景実行でこそ壊れていた。**
- 対処: `MosaicSupport/ProcessSuspension` を新設。1 秒周期のタイマーが**自分の発火間隔**を見張り、
  予定より大幅に遅れて発火したら中断とみなして `epoch` を進める（メインスレッドの状態と独立に判定
  できるのが要点）。計測側は開始時の `epoch` を控え、`didSuspend(since:)` が true ならサンプルを捨てる。
  適用: `MainThreadWatchdog`（hang / hang.begin の両方）・`BackgroundTrickle` の単位計測
  （face.photoMs / clip.embedMs / tags.photoMs / caption.photoMs）・`FacePerceptionAdapter` の
  load/infer（捨てた枚数は `suspended=N` としてログに残す）。
- 関連: `MosaicSupport/{ProcessSuspension,MainThreadWatchdog,Diagnostics}.swift`・
  `PerceptionCore/BackgroundTrickle.swift`・`MobileCLIPKit/FacePerceptionAdapter.swift`。
- 残課題: 中断の検出は 1 秒周期＋3 秒しきい値なので、3 秒未満の短い中断は取りこぼす（実害は小さい）。
- 教訓: **診断値は「測った条件」ごと疑う。**この汚染のせいで、同じログから 2 回誤った結論を出した
  （「メインが 29 分ブロック」「埋め込みが 4 時間で 64 枚」）。後者は `head`/`tail` で別々の実行を
  同一視した読み違いで、実際は 1 回の実行が 192 枚上限、6 回で約 1,000 枚進んでいた。
  **集計する前に、外れ値と実行境界を必ず確認すること。**

## バックアップが永久に始まらない（CLIP 埋め込みの残作業を待ち続ける）
- 症状: 実機ログに `bgtask: defer backup (embed backlog=44017)` が繰り返し出るだけで、夜間バックアップが
  一度も開始されない。
- 原因: [[ADR-72]] の「CLIP 埋め込みの残作業が **0** の窓でだけバックアップを開始」。意図（メモリ/IO の重い
  処理を同一窓で走らせない）は妥当だが、**残 0 に到達する見込みが無い**規模だと飢餓になる。
  実測では 1 窓あたり 192 枚（trickle の maxBatches 上限）で、残 44,017 枚 ＝ 約 230 窓ぶん必要だった。
- 対処: 連続して見送った回数を `AppSettingsKeys.backupDeferralStreak` に持ち、上限（3 回）に達したら
  埋め込みが残っていてもバックアップへ窓を 1 回明け渡す。バックアップは差分再開なので飛び飛びでよい。
- 関連: `HeavyWorkScheduler.runHeavyWork`・`AppSettingsKeys`。[[ADR-72]]。
- 教訓: 「A が終わったら B」は、A が有限時間で終わる保証がある時だけ成り立つ。**待ち合わせには必ず
  上限（タイムアウト・回数）を付ける。**

## メンバーストアが使い捨てられるたびに全体を再構築していた（18 秒で 546 回）
- 症状: 実機ログの起動直後、`merged.rebuild: local=6 cloud=0 total=6` が 18 秒間に **546 回**
  （毎秒 40〜61 回）記録される。`local=6` は 6 枚しか持たない小さなメンバーストア。
- 原因: `PlacePhotosView` / `AutoAlbumPhotosView` / `PersonAlbumView` / `DeviceAlbumPhotosView` の 4 画面が
  `_store = State(initialValue: .forMembers(…))` の形でストアを作る。**SwiftUI はビューの再評価のたびに
  `init` を実行する**ため（`State` は最初の値しか採らないので結果は捨てられる）、使い捨てストアが大量に
  生まれる。`MergedPhotoStore.init` が `observeStores()` を張っていたので、捨てられるはずのストアまでが
  `localStore.items` / `dropboxStore.items` の変化に反応して merge+sort を走らせていた。
  デバウンス（400ms）は**ストアごと**なので、インスタンスが増えると効かない。
- 対処: 監視の開始を `init` から `start()`（＝実際に画面へ出たとき）へ移す。`start()` されないストアは
  何も監視せずそのまま破棄される。4 画面の呼び出し側は変更不要。
- 関連: `PhotosFeatureKit/MergedPhotoStore.swift`。
- 教訓: SwiftUI の `init` は**何度でも走る**。`State(initialValue:)` に副作用のある生成を置かない。
  デバウンスはインスタンス単位なので、インスタンスが増える経路では防波堤にならない。

## ANE 直列化ゲートに穴があった（前景の CLIP テキスト塔が素通り／ゲート内で 3 並列）
- 症状: 実害は未観測（レビューで発見・予防的修正）。だが diagnostics-19（Vision `perform` が永久に返らず
  顔スキャンが 1 枚目で固まる）を起こす条件が、[[ADR-70]] のゲート導入後も**2 経路残っていた**。
- 原因: ゲートを **呼び出し側（夜間タガー）で掛ける**方式だったこと。ゲートは「包んだ経路」しか守らない。
  - **漏れ**: 前景の CLIP テキスト塔＝`QueryEmbedder` → `TextEmbedder.embed` と `AIAlbumService` の
    `prewarm` は誰も包んでおらず、Core ML 推論が無防備に走っていた。夜間の顔スキャン（Vision・ゲート内）と
    重なれば「Vision × Core ML 同時」が成立する。しかも AI アルバム作成は**ユーザーが起きている時間帯**の
    操作なので、夜間バッチと重なる現実的な窓がある。`CLIPDisplayLabeler.prewarm` は包まれていたのに、
    同じテキスト塔を使う検索経路だけが漏れていた＝**包み忘れが起きやすい方式だった**ことの証左。
  - **内側で自壊**: `TagTagger` はゲートを取った内側で `VisionTagAdapter.senseInfo` を呼び、その中の
    `boundedConcurrentResults(maxConcurrent: 3)` が `VNImageRequestHandler.perform` を **3 本同時**に
    走らせていた。「ANE は同時に 1 つ」という不変条件を、ゲートの内側で破っていた。この並列化は
    ゲート導入前の判断が残ったもので、両者は両立していなかった。
  - 副次: provider 呼び出し全体を包んでいたため、**画像ロード（ANE を使わない I/O）までゲート内**に入り、
    その間ほかの推論が全部止まっていた（`FacePerceptionAdapter` が load/infer を分けて計測していたのは
    まさにこの内訳を知るため）。
- 対処: ゲートを **ANE に触れる場所（`MobileCLIPKit` の各ランタイム/アダプタ）の内側**へ移し、呼び出し側の
  ゲートを全撤去（[[ADR-73]]）。非再入ゲートなので入れ子は致命的 → `@TaskLocal` で同一タスクの再入を
  検出して素通し＋`assertionFailure` の安全網を入れた。粒度は段ごと（顔観測／クロップ再検証／埋め込み、
  概念埋め込みは 1 語ずつ）に分け、1 回のゲートを長く握らないようにした。
  併せて: Core ML ロードを async 化（NSLock ＋同期ロードで協調スレッドを 16〜35 秒ブロックしていた）、
  CLIP/facenet を critical 圧迫で解放（従来は VLM のみ）、笑顔検出の `CIDetector` を写真ごとの生成から
  static へ（`context: nil` は毎回 `CIContext` を作る）＝[[ADR-74]]。
- 関連: `PerceptionCore/MLInferenceGate.swift`・`MobileCLIPKit/*`・`FaceCore/FaceTagger.swift`・
  `AutoAlbumCore/{TagTagger,PhotoTagger,AutoAlbumEngine+Recognition}.swift`。[[ADR-70]]・[[ADR-73]]・[[ADR-74]]。
- 残課題: 「ANE に触れたらゲートを取る」は規約（`CLAUDE.md`）とアサーション頼み＝機械的な強制ではない。
  `MLComputePlan`（iOS 17.4+）で INT8 CLIP・facenet が実際に ANE に載っているかは未検証（載っていない
  オペは CPU に落ちるので、直列化の必要範囲が変わる可能性がある）。
- 教訓: **横断的な不変条件（「同時に 1 つ」）を呼び出し側に守らせる設計は必ず漏れる。**リソースに触れる
  場所そのものに閉じ込めること。漏れは「新しい経路が増えたとき」ではなく「既にある別経路」で起きていた。

## Florence キャプションが実機で全写真同一の無関係テキストになる（fp16 デコーダの logits 乖離）
- 症状: VLM を Florence-2-base に替えたら、実機で生成されるキャプションが**どの写真も "Trump doing from…" 等の同一・無関係テキスト**（言語モデルの地の文＝ニュース調）になる。Mac（coremltools・**全 compute unit：CPU/GPU/ANE/ALL**）では "The image shows a gas pump with a sign that reads Please Prepay…" と正しい。
- 原因: **実機の fp16 デコーダ演算が Mac と乖離し、近接トークンの argmax が反転**（生成2トークン目が Mac=133('The') → 実機=140('Trump')）、そこから系列全体が破綻。段階的に切り分けた: (1) Mac 全 compute unit で ID・復号とも正常＝Swift ロジック/資産/トークナイザは無罪、(2) 実機ログで **encoder 出力は有限**（nonFinite=0・min/max・値域とも Mac と一致）＝encoder・fp16 NaN は無罪、(3) mask も全1で正常（Mac で mask=0 は空出力になり "Trump" 系ではない）、(4) 残るは**デコーダの fp16 数値**のみ。encoder は fp16 でも Mac と一致するのに、デコーダは fp16 で iPhone と Mac が食い違う（近接 logits の反転に敏感）。ANE を避けて CPU+GPU にしても実機 GPU の fp16 で同様に壊れた。
- 試した対処と結末: (A) VLM を ANE 回避（CPU+GPU）→ **実機 GPU の fp16 でも破綻・効果なし**。(B) デコーダ `compute_precision=FLOAT32`→ **実機 GPU では依然破綻**（fp32 でも GPU 経路は Mac と食い違う・かつ 184→367MB でメモリ悪化）。(C) `computeUnits=.cpuOnly` なら Mac の CPU_ONLY（検証済み・正しい）と一致する見込みだが、**CPU 固定は 3〜5秒/枚（Mac 実測 1.3秒）と遅く、Florence を選んだ最大の理由（ANE で速い）が消える**。→ **最終判断: Florence を撤回し SmolVLM-256M に戻す**（decoder-only で ANE 動作実績あり・速い。[[ADR-32]] 撤回）。誤キャプションは `captionModelVersion` を 5 に上げて全消去＆SmolVLM で付け直し。
- 関連: `scripts/convert_florence*.py`/`build_florence.sh`/`bench_vlm.py`（参考として残置）・`VLMRuntime`（SmolVLM に復元）・`CoreMLModelSupport`（cpuOnly 分岐撤去）・`AutoAlbumEngine.captionModelVersion`(→5)。[[ADR-32]]・[[ADR-11]]（CLIP fp16 の教訓）。
- 教訓: **Core ML の正しさは Mac だけでは検証しきれない**。Mac は全 compute unit で正しくても、実機 ANE/GPU の fp16 は encoder-decoder の cross-attention で Mac と乖離し得る（decoder-only では顕在化しない）。新モデル採用前に**実機での正しさ確認**（生成ID/有限性ログ）を段取りに入れる。今回は encoder=有限・mask=正常・fp32でも駄目、と 4 ラウンドの実機ログで切り分けた。

## フォルダ名アルバムを開くとヘッダーは「325 photos」なのにグリッドが空
- 症状: Dropbox のパス（フォルダ名）から作るアルバム（例「ヒロック」）を開くと、上部ヘッダーは「325 photos・期間」と出るのに、サムネイルグリッドが**真っ白（0 件）**。クラウド本体（Cloud ソース）は正常に表示される。
- 原因: **保存済みフォルダアルバムのメンバー（クラウドパス）が現在の `dropboxStore.items` と 1 件も一致していなかった**。実データを SwiftData から直接確認して確定: アルバムのメンバーは `C-/写真/ヒロック/…jpeg`（325件）だが、現在の Dropbox キャッシュ（`ZCACHEDDROPBOXITEM`）は全て `/mosaicphotos/iphone-e7ec95/img_XXXX.jpg`＝**別 Dropbox アカウント時代のパス**が残存。`MergedPhotoStore.filteredCloudItems` は `filter.contains($0.path)` の完全一致なので交差が空→ `merged.rebuild: local=0 cloud=0 total=0`（診断ログで確認）。真因は「**フォルダアルバムは起動時に SwiftData から読むだけで再生成されない**」こと。`generate()`（起動時・版ゲート）は**エンリッチ台帳**からパスアルバムを作るが台帳にも旧アカウントのクラウドパスが残るため旧パスのまま。現在の一覧を出典にする `generateFast()`（=`generatePathAlbums`）は**セクションの更新ボタンでしか走らない**。結果、アカウント/フォルダ構成が変わると保存済みメンバーが現存パスとずれ、開いても 0 件になる。
- 対処: `AutoAlbumEngine.loadOrGenerate` の遅延セクションで、`pathAlbumsEnabled` のとき `generatePathAlbums()`（現在の `cloudProvider.cloudPhotos()`＝`dropboxStore.items` を出典）を毎起動走らせて**自己修復**。存在しないパスのアルバムは消え、現存フォルダのアルバムは現行 `item.path` で作り直される（＝フィルタと必ず一致）。ログで検証: `pathAlbum.fast: metas=7396 → done albums=20`。パスは path_lower で一貫（`DropboxFileItem.path`＝`path_lower`、`CloudPhotoMeta.path`＝`item.path`、`PhotoRef` は前置詞のみで無損失）なので、同一出典で作れば一致は構造的に保証される。
- 関連: `AutoAlbumEngine.loadOrGenerate`（自己修復追加）・`PathAlbumGenerator.generateFast`/`computeFromEnriched`・`MergedPhotoStore.filteredCloudItems`・`AutoAlbumInfo.cloudPaths`。
- 残課題: 旧アカウントのクラウドエンリッチ/顔レコードが台帳に残る（別アカウントへ切替時の一括パージは未実装）。**ビジュアル検証はシミュレータのスクリーンショット＋SwiftData 直読み＋診断ログ**で行った（実機不要の切り分け）。

## ピープルの代表顔が食べ物/桜など「顔でない領域」になる（誤検出・回転ではない）
- 症状: ピープルのカルーセルで一部の人物（例 Person 3 / Person 29）の代表顔アバターが、**料理や桜など顔でない領域**を切り抜いている。ユーザー体感は「顔の切り取り位置が写真の縦横回転を考慮していない」。
- 原因（切り分け）: 回転クロップのズレではなく**顔の誤検出**の可能性が高い。(1) 検出（`loadLocalCGImage`）もアバター（`requestAspectCGImage`→`loadFaceAvatar`）も**両方 `.highQualityFormat`＋`orientationNormalizedCGImage`（.up 正規化）を通る**ため、box とクロップの向きは一致する（＝回転ズレは起きにくい）。(2) SwiftData 直読みで Person 3（clusterID=2）の代表は自動選択（`coverFaceID` 未設定）で、クラスタ内の顔は**全て quality=1.0（＝品質信号が取れないときの既定値）**、box 座標（0.46,0.44,0.22×0.29）は写真中央の妥当な位置。**quality が一律 1.0＝Vision の品質/ランドマークが機能せず、食べ物・模様を「顔」と誤検出したもの**が品質ゲートを素通りして代表になったと推測（シミュレータの顔検出は device 校正前提のため信号を出せない＝実機と挙動が異なる）。
- 対処: 未対応（本コミットでは記録のみ）。候補: (a) `faceScanVersion` を上げて実機で再スキャン（現行ゲート ADR-48/52/53 が誤検出を弾く・stale 一掃）、(b) 誤検出耐性のゲート強化。**シミュレータ計測ではなく実機データで判断すべき**（face-accuracy 台帳の方針）。
- 関連: `PeopleSupport.loadFaceAvatar`/`requestAspectCGImage`・`FacePerceptionAdapter`（quality=1.0 の既定）・`FaceStore+People.bestCoverFace`・`FaceQualityGate`。[[ADR-48]]/[[ADR-52]]/[[ADR-53]]。
- 残課題: 併発していた「グリッドサムネ 90° 横倒し」は真因特定のうえ解決（下記の別項）。

## グリッドのサムネで縦横写真が 90° 横倒し（真因＝小さい targetSize・PHImageManager の埋め込みサムネ）
- 症状: 端末写真のグリッド（人物/場所/端末アルバム）で、一部の縦横写真が **90° 倒れて**表示される。同じ写真をフル画面で開くと**正立**。カバー（カルーセルの角丸）も概ね正立。顔アバターの切り抜きズレも同根と疑われた。
- 切り分け（シミュレータ＋キャッシュ都度クリア＋スクショで A/B）: 以下を1つずつ変えても**横倒しのまま**＝いずれも無関係と確定 — `resizeMode`（.fast/.exact）、`deliveryMode`（.opportunistic/.highQualityFormat）、画像マネージャ（`PHCachingImageManager`/`PHImageManager.default()`）、`contentMode`（.aspectFill/.aspectFit）。**唯一効いたのは targetSize**：グリッドの約 465px 要求だと横倒し、**1024px 要求で全写真が正立**、続けて **640px でも全解消**（465 では発生）。
- 原因: **PHImageManager は小さい targetSize 要求に対し、一部写真で「向きの狂った（EXIF 未適用の）埋め込み/OS サムネ」を返す**。大きい要求（≥640）だとフル画像から正しい向きでデコードするため正立になる。フル画面が正しかったのは大サイズ要求だったから。顔検出は 1024px 入力なので影響なし、顔**アバター**（200〜480px）は影響を受け得た。
- 対処: 取得を **`orientationSafePixel`(=640) 下限**で行い、表示・キャッシュはセルサイズへ**縮小**する（`PHAssetImageLoader.orientationSafeSize` / `resizedUp`）。**キャッシュ保存サイズ・容量は不変**（縮小してから保存・キーもセルサイズ）。増えるのは未キャッシュ写真の初回デコードのみ（約1.9倍・以後キャッシュ）。先読み（`startCachingImages`）も同じ 640 下限に揃えてヒットを保つ。表示系（グリッド `thumbnailStages`/`requestThumbnail`・カバー `loadLocalCover`・顔アバター `requestAspectCGImage`・キャプション）に適用。**CLIP 埋め込み/顔検出は `renderFloor: 0` で従来の入力を維持**（知覚を変えない）。
- 関連: `PHAssetImageLoader`（orientationSafePixel/orientationSafeSize/resizedUp/renderFloor）・`LocalPhotoStore`(startPrefetch)・`LocalPhotoStore+PhotoStore`(thumbnailStages/requestThumbnail)・`AILanguageAdapters.loadLocalCGImage`(renderFloor:0)。[[ADR-62]]（画像ローダ統一の続き）。検証: シミュレータのスクショで人物アルバム全写真の正立を確認。
- 教訓: PHImageManager は**小さいサムネ要求で向きを落とすことがある**。向きが要る用途（グリッド・顔クロップ）は一定サイズ以上で取得して縮小する。deliveryMode/resizeMode/manager を疑う前に **targetSize を疑え**。

## Dropbox のサムネイルが 3 列グリッドでぼやける（w128h128 の約2倍引き伸ばし）
- 症状: サムネイルビュー（3 列）で Dropbox 写真だけがぼんやりする。端末写真はくっきり。
- 原因: Dropbox サムネの取得サイズが **w128h128** 固定なのに対し、3 列のセルは実描画 **約260px**（画面約130pt×スケール2・要求は320pxバケット）＝`scaleAspectFill` で**約2倍に引き伸ばし**。端末写真は PHImageManager が要求サイズどおり返すため差が出る。128px は 5 列以上の高密度表示を想定した値で、1〜4 列では不足。
- 対処: `thumbnailAPISize` を **w256h256** に引き上げ（案A・1〜4列をカバー）。追従して (1) メモリ件数上限の換算を 64KB→256KB/枚に（下限 800→300 枚・バイト上限は予算算出のまま）、(2) **サイズ変更マーカーで旧キャッシュを一度だけ全消去**——ファイル名（SHA256(path).jpg）にサイズが入らないため、放置すると旧 128px がそのまま使われ続ける。LRU 削除もファイル名再計算ベースなので**命名変更では旧ファイルが孤児になる**＝マーカー方式（UserDefaults にサイズを記録・不一致なら thumbnails ディレクトリ＋使用量エントリをクリア）が正解。マーカー無し（旧版からの更新）と初回インストールは区別できないため**無条件クリア**（初回は空で no-op）。
- 副次効果: クラウド写真の AI 解析（CLIP 224px 入力・シーンタグ・顔検出=ADR-33・VLM）はこのキャッシュ済みサムネを再利用しているため、**解析入力も 128→256px に向上**（特に顔検出の取りこぼし改善が見込める）。
- トレードオフ: 通信・ディスクが約3〜4倍/枚（数KB→十数KB・初回同期が主）。デコード後メモリ4倍/枚＝メモリ層に載る枚数減（コスト上限ベースの NSCache が自動調整・圧迫時は MemoryPressureMonitor の段階縮小）。
- 関連: `DropboxInternalConstants.thumbnailAPISize`(w256h256)・`+Tuning`(件数換算)・`DropboxCacheStore`(サイズ変更マーカー)・`MemoryBudget.thumbnailCostLimit`。[[ADR-33]]（クラウド顔検出はサムネサイズに追従）。

## AI アルバム「太郎と花子」が 0 件／「人のいない風景」に人物写真が混入（実機・一晩運用）
- 症状: (1) ピープルに「山田太郎」「山田花子」があるのに、AI アルバム「太郎と花子」で写真がピックアップされない。(2)「人のいない風景」アルバムに人が写った写真が入る（ADR-35 導入の翌朝に観測）。
- 原因:
  - (1) 人物名の接地（ADR-29）は正しく `.people(["山田太郎",…])` を作るが、照合先の `EnrichedPhoto.people` は**初回エンリッチ時に一度だけ焼き込まれ、以後更新されない**（`enrichLocal` はエンリッチ済み refKey をスキップ・peopleMap は新規写真のみ）。顔クラスタは最初は無名（"Person N"）で**後から**命名されるため、ほぼ全写真が「命名前」にエンリッチ済み＝people は空のまま。ハード条件なので 0 件。ADR-29 は「リネーム直後は旧名が残り得る」と注記していたが、実際は再エンリッチの仕組み自体が無く恒久の問題だった。
  - (2) 多層の穴の複合。主犯は **ADR-35 のマルチプローブが除外対比を弱めた回帰**：除外は「neg ≥ max(肯定)」の相対判定で、プローブが肯定の最大値を底上げすると落ちにくくなる（ハーネスでも精度 0.99→0.96 と観測・導入翌晩に顕在化）。副次: 顔検出は「顔」であって「人」ではない（後ろ姿・遠景は faceCount=0 で素通り・クラウドは 128px でさらに取りこぼし）／Vision 語彙（実測 1303 クラス）には people の他に adult・child・crowd があり除外語 "people" と部分一致しない／審査の unsure→keep は除外系では逆向き。
- 対処（ユーザー選択: 1=恒久案・2=プローブ対策のみ）:
  - (1) **人物条件の live 照合**: `QueryEvaluator.hardFilter` に `peopleByRefKey`（PeopleEngine の現在のクラスタ名・refKey→名前）を渡し、`.people`/`.peopleAtLeast` は焼き込みでなく live マップで評価（未収載は焼き込みへフォールバック）。seam は faceCounts と同型（`AIAlbumService.peopleByRefKeyProvider`・人物条件があるアルバムのみ取得・`setPeopleByRefKeyProvider` で Composition Root から結線）。命名/統合/クラスタ成長が**即**検索に反映される。
  - (2) **除外語があるアルバムではプローブを使わない**（`QueryEmbedder.embed` で excludeTerms 非空なら probes 無視＝ADR-35 以前の対比挙動を維持）。埋め込みの唯一の実装点で無効化するのでフル評価・増分評価の両方に効く。
- 関連: `QueryEvaluator`(peopleByRefKey)・`QuerySpec.hasPeopleConditions`・`AIAlbumService`(peopleByRefKeyProvider/peopleMapIfNeeded)・`AutoAlbumEngine.setPeopleByRefKeyProvider`・`AutoAlbumAdapters`・`QueryEmbedder.embed`(除外時プローブ無効)・`PeopleLiveMatchTests`/`MultiProbeTests`。[[ADR-29]]・[[ADR-35]]。
- 残課題: (2) の副次の穴は未対応＝タグ除外の人系同義語（adult/child/crowd）正規化・除外系審査の unsure→drop・人体検出（`VNDetectHumanRectanglesRequest`＝後ろ姿対応）の導入。審査の証拠行に人物名が無く、人物アルバムのメンバーを審査が誤 drop し得る点も未対応（実機で観測されたら追加）。

## AI アルバム作成/更新でシートが固まって見える（重い検索を待ってから閉じていた）
- 症状: AI アルバムのコンポーザーで「アルバムを更新／作成」を押すと画面が固まる。タップに反応した手応えが無く、しばらくして閉じる。
- 原因: `AIAlbumComposerView.submit()` が `await engine.updateAIAlbum/createAIAlbum` の**完了を待ってから** `dismiss()` していた。作成/更新は決定的プレビューでも「全写真メタの取得（`allEnrichedPhotosLite`・85k）＋タグ台帳取得（`allTags`）＋数万件×512 次元のスコアリング」を伴い数秒かかる。スコアリング自体は `Task.detached` でオフメインだが、シートは結果を待つ間ずっと開いたままで、`BusyLabel`（"Searching…"）は出るものの体感は「固まった」。ユーザーはタップが効いたのかも分からなかった。
- 対処: **作成/更新を待たずに即 dismiss** する方式へ変更。(1) `AutoAlbumEngine.beginMakeAIAlbum(id:title:criteria:)` を追加＝実処理を engine 保持のバックグラウンド Task で走らせ（シートより長生き）、`isMakingAIAlbum` フラグを立てる。(2) コンポーザーの Button は同期 `submit()` で `beginMakeAIAlbum` を呼び即 `dismiss()`。(3) 進捗フィードバックは **AI アルバムのセクションヘッダーのスピナー**（`sectionHeader("AI Albums", isBusy: engine.isMakingAIAlbum)`）で示し、完了時に `aiAlbums`（Observable）更新で自動的にカルーセルへ反映。0 件でも保存され、取り込みが進めば背景で自動的に埋まる設計は不変。空検索はボタン無効化＋`beginMakeAIAlbum` 内でも二重ガード。
- 関連: `MosaicPhotos/Home/AIAlbumComposerView.swift`（submit を同期化・即 dismiss）/ `AutoAlbumCore/AIAlbum/AutoAlbumEngine+Recognition.beginMakeAIAlbum` / `AutoAlbumEngine.isMakingAIAlbum` / `MosaicPhotos/Home/HomeSections.swift`（AI Albums ヘッダーの isBusy 結線）。[[ADR-23]]（解釈は作成時 1 回・プレビューは決定的）。
- 残課題: 作成直後にアルバムがカルーセルへ現れるまで数秒あり、その間はヘッダーのスピナーのみが手掛かり（空アルバムを即挿入してから埋める方式は今回入れていない）。

## CI（iOS シミュレータ）で DropboxCore テストが 194 秒ハング→TEST FAILED
- 症状: GitHub Actions の iOS ジョブで `DropboxCore` のテストが失敗。ログにはテストのアサーション失敗が一切無く、`Testing started completed. 194.161 sec` の後に `** TEST FAILED **`（exit 65）。ローカル（iPhone 17 Pro）では 50 テストが約 1.4 秒で成功し**再現しない**。
- 原因: `DropboxSyncEngine.pollLoop` が、longpoll が `changes:false` を返したとき**待ちを一切入れず即座に再 longpoll する**構造だった。本番の longpoll はサーバ側で最大 30 秒ブロックするのでビジーループ化しないが、テストのスタブ（`routingStub`）は即座に返すため**タイトなビジーループ**になる。`pollLoop` は `@MainActor` なので、この busy loop が毎反復 `onStateChanged(.polling)` を叩きつつ main actor を占有し、遅い CI ランナーでは `waitUntil`/`stop()` など他の main-actor 作業が飢餓。テスト全体が進まず 194 秒で打ち切られて FAILED になっていた（ローカルは速いので `stop()` が即通り顕在化しない＝フレーク）。ジョブは `continue-on-error`（best-effort）だが赤バッジは出る。
- 対処: no-changes 経路に**協調的な最小待ち**（`DropboxInternalConstants.pollNoChangeMinDelayNs = 1s`＋`Task.sleep`＋cancel 時 break）を追加。本番は longpoll が既に約 30 秒ブロックするので実害ゼロ、テストはビジーループが消えて決定的になる（`stop()` テストは cancel で sleep を即中断して終了）。CI と同フラグ（`-retry-tests-on-failure -test-iterations 2`）でローカル成功を確認。
- 関連: `Sync/DropboxSyncEngine.pollLoop`（no-changes に guard sleep）/ `Networking/DropboxInternalConstants.pollNoChangeMinDelayNs`（新設）/ `.github/workflows/ci.yml`（ios は best-effort）。[[ADR-10]]（GitHub を CI に活用）。
- 残課題: longpoll が異常に早く返り続ける本番ケース（サーバ障害等）でも 1s 間隔に律速される＝過剰ポーリングを防げるが、指数バックオフまでは入れていない（現状は error 経路のみ 30s）。

## フル画面ビューで最上部のアクティビティバーと日付が重なる
- 症状: フル画面の写真ビューで、最上部のアクティビティバー（ツールチップ状の表示）と日付が同じ位置に重なって読めない。
- 原因: アクティビティバーは `SourceHostView` の `overlay(alignment:.top)`（安全領域上端）に出す。一方フル画面の日付は `PhotoPageView` の**ナビバー principal タイトル**で、これも安全領域上端の中央＝**同じ位置**だった。
- 対処: 日付をナビバータイトルから外し、`PhotoPageView` を **`ZStack(alignment: .top)`** にして安全領域上端基準に固定、写真(TabView)は `ignoresSafeArea` で全画面のまま、日付を上端から少し下げて**バーの下**へ置く。バーは `padding(.top, 0)` で最上端へ。
  - 補足1: 最初 `overlay + GeometryReader.safeAreaInsets` で組んだが、`ignoresSafeArea` 配下では inset 取得が不安定で日付が画面中央に出た。`ZStack(.top)` 基準（安全領域上端）に変更して安定。
  - 補足2: 「バーのすぐ下に寄せたい」要望に対し、ナビバーが残っていると安全領域上端がナビバーの**下**になり 1 段ぶん隙間が空く。**ナビバーを `toolbar(.hidden)` で隠してカスタム戻るボタン（左上 chevron・`@Environment(\.dismiss)`）**に置換し、ラベル基準＝アクティビティバー位置にしてすぐ下へ寄せた。トレードオフでエッジスワイプ戻しは無効になる（戻るボタンで代替）。
  - 補足3: あわせて位置情報のある写真は**日付の下に地名**を表示（`task(id: currentID)` で `store.location(for:)`→`PlaceNameResolver.placeName`。オフライン DB なので即時）。
- 関連: `PhotoPageView.swift`(topControls / resolveCurrentPlace) / `DropboxActivityBar.swift`(modifier)。
- 残課題: ナビバー非表示でエッジスワイプ戻しが効かない（戻るボタンで代替・許容）。

## 旅行アルバムが「Trip」で固定／位置情報のない写真が混入
- 症状: 時間と場所アルバムで、(1) 座標はあるのに名前が「Trip」のまま、(2) EXIF/位置情報のない写真が混ざる。
- 原因:
  - (1) 名前はメンバーの逆ジオコーディング地名（`placeName`）の最頻値。未解決なら centroid を `CLGeocoder` で逆引きするが、`PlaceNameResolver.components` が**逆引き失敗（空）を恒久キャッシュ＆ディスク永続**（「連打防止」コメント）。一括生成のレート制限で失敗→空固定→ネット回復後も**永久に「Trip」**。「地名なし（海上）」と「一時失敗」を区別していなかった。
  - (2) `TimePlaceStrategy.backfillCoordinates` が、座標のない写真へ**時間的に最も近い GPS 写真の座標を時間差の上限なしで付与**。これで未測位写真が away 判定され旅行へ混入（backfill しなければ `isAway` は座標無しで false＝そもそも入らない）。
- 対処:
  - (1) 逆ジオコーディングを**同梱DB（GeoNames cities15000）で完全オフライン化**（[[ADR-21]]）。失敗概念が消え、決定的に解決＝「Trip」固定が解消。
  - (2) **backfill を廃止**し、座標のある写真のみを旅行対象に（ユーザー要望「位置情報がない写真は入れない」）。
  - **既存アルバムは生成時に名前を保存する**ため、修正だけでは「Trip」が残る（`storedVersion == generationVersion` で再生成スキップ）。`AutoAlbumEngine.generationVersion` を 3→4 に上げ、起動時1回の自動再生成で地名付きへ作り直す。
- 関連: `TimePlaceStrategy.swift`(backfill 削除) / `AutoAlbumEngine.resolvePlaceIfNeeded` / `PlaceNameResolver`・`OfflinePlaceDB` / `TimePlaceStrategyTests`。
- 残課題: 命名は「最も近い既知都市」。多都市旅行で centroid が半端な都市を指す場合があり、代表クラスタ座標での命名は今後の改善余地。地名は表示言語に追従（日英両方を bin に保持し AppLocale で切替・日本語が無ければ英語）で対応済み。

## サムネ遅延の主因がネット→ディスク再デコードへ移動（メモリ保持＋デコード並列制限）
- 背景: 前項の改善後に再計測。効果は確認できた（ミス率 59%→35%→2.5%、ミス待ち 17s→8.7s→0.57s）。だが新たな主因が顕在化。`thumb-drain` カウンタで `cache.thumb.diskHit=1787(Σ230409ms)`＝**1枚 ~129ms**、`memHit=56`（=メモリにほぼ残らず毎回ディスク再デコード）。
- 原因:
  - **メモリ保持が弱い**: Dropbox サムネのメモリ層が 48MB/1000件（128px≈64KB→約740枚）で、数千枚スクロールで溢れて再デコード。加えて `MemoryImageCache` の critical 圧迫が `removeAllObjects()` で**全消去**し、閲覧中に残りを毎回デコードし直す storm を誘発（footprint ~400MB で圧迫が起きやすい）。
  - **デコードのスレッド過多**: ディスクデコードが要求ごとに**無制限の `Task.detached`**（1ドレインで1787本）を生み、ネット応答デコード・CLIP タガー・grid 再構築と CPU を奪い合い、本来数msのデコードが ~129ms に膨張。
- 対処（N1 メモリ保持＋N2 デコード並列制限）:
  - `MemoryImageCache` に `purgeOnCritical`（既定 true）と per-instance `pressureFloor` を追加。**サムネキャッシュは `purgeOnCritical: false`**（critical でも全消去せず下限まで段階縮小＝直近を残す）。Dropbox/Local 両サムネに適用。
  - Dropbox サムネのメモリ上限を 48MB/1000→**80MB/1600**、圧迫下限を 16MB→**40MB** に引き上げ保持を厚く。
  - `AsyncSemaphore`（ImageCacheKit）を追加し、**サムネのデコード同時数を端末コア数依存（`max(2, cores-2)`）に制限**（`ThumbnailDecode.limiter`）。ディスク decode（`DropboxCacheStore+Binary`）とネット応答 decode（`DropboxThumbnailBatcher`）の両方が共有。
- 関連: `ImageCacheKit`(MemoryImageCache・AsyncSemaphore) / `DropboxInternalConstants`(上限/下限/並列) / `DropboxCacheStore`(+Binary) / `DropboxThumbnailBatcher` / `LocalPhotoCore.ThumbnailCache`。
- 残課題: 効果は再度 PerfTrace（`memHit/diskHit` 比、`diskHit` の ms）で確認。footprint 自体の削減（merged/grid・~400MB）は別途で、これが下がれば圧迫由来の縮小も減る。
- 追補（再計測→N2 再調整＋N3）: N1+N2 適用後の再計測で **ミス率59%→10%・ミス待ち17s→2.8s・memHit 56→2081** と大幅改善。ただし `diskHit` が依然 ~101ms（実デコードは ~3ms＝大半はセマフォ待ち＋ディスクI/O）。そこで (N2 再調整) ディスクデコードの上限を `max(2,cores-2)`→**`max(4,cores)`** へ引き上げ、ネット応答デコードは（バッチ並行数で既に有界なので）セマフォから**外して分離**＝相互の待ちを解消。(N3) 背景再埋め込み中の AI フル再検索（全件 fetch＋採点で footprint ~200→400MB へスパイク）の周期を `batch%16`→**`batch%48`** に間引き、ピーク発生頻度を 1/3 に下げて圧迫イベントを削減（サムネ保持も安定）。最終結果は完了時の onBatch で必ず反映。

## アルバムのカバー（タイトル写真）が粗い＝128px サムネの拡大だった
- 症状: アルバムカルーセルのカード（`AutoAlbumCard`・150pt）のクラウド写真カバーが粒状で見づらい。
- 原因: クラウドカバーが `dropboxStore.thumbnail(for:)`（Dropbox の **128px** サムネ）を 300px(@2x) のカードへ拡大表示していた。ローカルカバーは `loadLocalCover(pixelSize:300)`（PHImageManager・原画から）で問題なし。
- 対処: `DropboxPhotoStore.coverImage(for:maxPixel:)` を追加。**フル画像バイト**（キャッシュ優先、無ければ DL＋保存＝ビューアと共用）から `ImageDownsampling.downsample(maxPixel:)` で**カバーサイズ(300px)へ縮小**して生成。原画由来で鮮明、かつ 1600px ではなくカバーサイズへ落とすので常駐メモリも軽い（カバー多数でのスパイク回避）。`AutoAlbumCard` のクラウド分岐をこれに差し替え。
- 関連: `DropboxPhotoStore`(coverImage) / `MosaicPhotos/Home/HomeRows.swift`(AutoAlbumCard)。`ImageDownsampling.downsample` は maxPixel 可変。
- 残課題: 48pt の小さな一覧行（`PlaceRow`/`AlbumRow`）は 128px サムネのままで十分（拡大なし）なので据え置き。

## Dropbox の体感遅延を計測して三方向で改善（先読み行列・同期O(N²)・CLIP競合）
- 背景: 実機で Dropbox の閲覧・同期が重い。下記の計測ハーネス PerfTrace の実機ログで原因を3つに切り分けた。(1) サムネ取得の行列待ち（ミス1枚あたり平均~17秒・ミス率~59%、`net.get_thumbnail_batch` は25枚で~1.9s）、(2) 初回同期がページごとに全件再読み込み（`cache.fetchItems` 0.85s/回が約40回＋毎回 merged/grid 再構築）、(3) CLIP 再埋め込み(v0→7・85k枚)がサムネのデコード/CPU と競合（モデル初回ロード14〜37s）。
- 原因の核心:
  - 先読みに**キャンセル経路が無く**（`prefetchItemsAt` のみ実装、`cancelPrefetchingForItemsAt` 未実装）、`prefetch` は `Task{ thumbnail() }` を撃ちっぱなしで `pendingItems` が画面外に出ても消えず、3000件級の行列に。可視セルと先読みに**優先度差も無い**。
  - 同期エンジンが delta ページごとに `onCacheUpdated()` を呼び、`DropboxPhotoStore` が全件 `cachedItems()`＋`items=` 再代入→`MergedPhotoStore` 全マージ→グリッド全再構築を約40回。既存スロットル(0.4s)はページ間隔(1〜3s)より短く無効。
  - 背景タガーの `shouldPause` がスクラブとメモリ圧迫のみで、クラウド閲覧中の競合を考慮せず。
- 対処:
  - サムネバッチャ(`DropboxThumbnailBatcher`)を**2段優先キュー**へ刷新：可視(`thumbnail(for:)`・待機者あり)=最優先FIFO、先読み(`prefetch`・待機者なし)=低優先LIFO＋**上限600**。各ウェーブは可視→先読みの順で充填。`cancelPrefetch` を実装し `cancelPrefetchingForItemsAt`→`PhotoLoading.cancelPrefetch`→バッチャで**未取得の先読みを破棄**。先読みは `thumbnailExists`（メモリ/ディスク存在を**非デコード**判定）で既存分を除外。`inFlight` で二重フェッチ防止。
  - 初回同期の UI 反映間隔を**状態依存**に（`initialSync` は 5s に間引き、polling は 0.4s）。完了時は `forceCacheRefreshSoon()` で即時最終反映。約40回→数回へ。
  - タガーの `shouldPause` に `BackgroundActivityMonitor.cloudThumbnailBusy`（バッチャのドレイン中フラグ）を追加し、**クラウド閲覧中は背景埋め込みを譲る**。
- 関連: `DropboxThumbnailBatcher` / `DropboxPhotoStore`(cancelPrefetch・refresh間引き) / `DropboxCacheStore+Binary`(thumbnailExists) / `ImageCacheKit.DiskImageStore`(fileExists) / `PhotoLoading`(cancelPrefetch) / `PhotoCollectionView`(cancel handler) / `MergedPhotoStore` / `MosaicSupport.BackgroundActivityMonitor`(cloudThumbnailBusy) / `AutoAlbumEngine+Recognition`(shouldPause)。
- 残課題: ネット往復1.9s/25枚は固有（並列数 `maxConcurrentRequests` は設定で調整可だが429注意）。初回同期の増分マージ化、メモリピーク(~696MB)削減は別途。効果は再度 PerfTrace ログで定量確認する。

## Dropbox パフォーマンス計測ハーネス（PerfTrace・ON/OFF 可・コードに常駐）
- 背景: 実機で Dropbox 周りの動作が重い。原因の切り分けのため、ホットパスに常駐の計測コードを入れ、必要時だけ ON にして同じ計測を再現できるようにした（計測→ON、計測後→OFF、コードは残す方針）。
- 仕組み: `MosaicSupport/PerfTrace.swift`。既定無効で、無効時は各 API が先頭で即 return するためオーバーヘッドは無視できる。ON/OFF は 2 通り = (1) コンパイルスイッチ `-DMOSAIC_PERF`（OTHER_SWIFT_FLAGS）で既定 ON、(2) 実行時 `PerfTrace.isEnabled`（Developer Options のトグル「Performance tracing (Dropbox)」で実機切替・`AppSettingsKeys.perfTracing` に永続化し起動時反映）。出力は os_signpost（Instruments の Points of Interest）と DiagnosticsLog（端末内ログ・Developer Options から閲覧）。API は `measureAsync` / `logSpan(ms:detail:)` / `mark` / `count(value:)` / `flushCounters(context:)`。
- 計測点（Dropbox）:
  - ネットワーク往復: `DropboxAPIClient.send` が `net.<endpoint>`（例 net.get_thumbnail_batch / net.download / net.list_folder）の ms とバイト数・status を 1 行出力。RPC・content・同期はすべてここを通るので一括カバー。最重要指標。
  - サムネ: `DropboxThumbnailBatcher` で `thumb.cacheHit/cacheMiss`、ミス時の待ち `thumb.missWaitMs`、チャンクの `thumb.decodeMs` と `thumb.decodedItems` を集計し、1 ドレイン完了ごとに `flushCounters("thumb-drain")` で 1 行サマリ。
  - キャッシュ層: `DropboxCacheStore.thumbnail` が `cache.thumb.memHit / diskHit(ms) / miss` を集計。
  - 全件メタ: `DropboxCacheStore.cachedItems` が `cache.fetchItems`（SwiftData 全件 fetch+変換の ms）。
  - フル画像: `DropboxPhotoStore.fullImage` が `fullImage.cacheHit` / `fullImage.download`（ms・KB）。
- 関連: `Packages/MosaicSupport/Sources/MosaicSupport/PerfTrace.swift` ほか上記各ファイル、`MosaicPhotos/Settings/DeveloperSettingsView.swift`（トグル）、`MosaicPhotosApp.swift`（起動時反映）。
- 残課題: 計測結果に基づく改善（プリフェッチ窓・並行数・キャッシュ命中率・初回同期）の最適化は別途。同じ枠組みで他機能にも横展開できる。

## 実機クラッシュ: カバー取得で continuation を二重 resume（PHImageManager .opportunistic）
- 症状: 実機起動直後に `SWIFT TASK CONTINUATION MISUSE: loadLocalCover(_:pixelSize:) tried to resume its continuation more than once` で停止。診断ログには無害な `accounts Code=7` / `Failed to get or decode unavailable reasons` も併発（クラッシュ原因ではない）。
- 原因: `loadLocalCover`（`HomeRows.swift`）が `PHImageRequestOptions.deliveryMode = .opportunistic` を使用。opportunistic は「劣化版→確定版」と**結果ハンドラを複数回呼ぶ**仕様で、毎回 `continuation.resume(returning:)` していたため二重 resume で fatalError。写真がある実機ほどカバー取得が走り発症しやすい。
- 対処: deliveryMode を**単一コールバックの `.highQualityFormat`** に変更し、さらに `NSLock` + `didResume` フラグで **resume を一度きりに保証**（将来 opportunistic へ戻しても安全）。ハングも避けるため確定版を待つのではなく最初の確定コールバックで resume。
- 関連: `MosaicPhotos/Home/HomeRows.swift`。併せて存在しない SF Symbol `cloud.slash`（`No symbol named 'cloud.slash'` 警告）を `icloud.slash` に修正（`DropboxPhotoStore+PhotoStore.swift` / `HomeSections.swift`）。
- 残課題: 他にも `withCheckedContinuation` で外部コールバックを包む箇所は、複数回呼ばれ得る API（Photos/旧 API）に注意。one-shot ガードを定石にする。

## 月グループで疎な月が密に表示されない（coalesce しきい値が perf 最適化で固定4に劣化）
- 症状: 写真の少ない月が多いと、月グループ表示で「ヘッダー＋半端な1行」が並んで疎になる。特定ビュー限定に見えるが、実際は全ソース/アルバムビューが共通の `PhotoGridView`→`PhotoCollectionView` を使うため挙動は全ビュー共通。
- 原因: 当初（ea80c1ab）は coalesce しきい値＝**実列数**（monthGroup は 15）で、1行に満たない連続月を範囲セクションに束ねていた。だが perf 最適化（29291a25「列変更＝ピンチで再構築しない」）でスナップショットのシグネチャから列数を外した副作用として coalesce を**固定値 4** に変更してしまい、monthGroup（15列）で 4〜14枚の月が束ねられず疎のまま残った。
- 対処: coalesce しきい値を実列数へ戻す（`grouping==.month ? max(1, columns) : 0`）。grouping==.month の列数はズーム段階で固定（dense/year では coalesce=0 で不変）なので、シグネチャに `c<coalesce>` を加えてもピンチ（dense/year の列変更）では再構築が起きず、perf 配慮（68k で再構築を繰り返さない）は維持。`applySnapshot(coalesce:)` で受け渡し。表示は全ビュー共通＝1か所の修正で全体に適用される。
- 関連: `PhotoSourceKit/Views/PhotoCollectionView.swift`（signature/applySnapshot）、`Support/PhotoGridGrouping.swift`（coalesceBelow）。
- 追補（最大密度パッキングへ強化）: しきい値を実列数に戻しても、(a) 大きい月に挟まれた**孤立した小さい月**、(b) 各セクション末尾の**半端な行**、が残り疎に見えた。`photoGridSections` の束ね処理を「連続月を 1 行ぶん（列数）に達するまで貪欲に蓄積して区切り、末尾の 1 行未満の余りは直前セクションへ畳み込む」**最大密度パッキング**に変更（ラベルは複数月で範囲 "YYYY-MM – YYYY-MM"）。これで各セクションは最低 1 行ぶん埋まり、孤立小月・半端行の量産を解消。ユーザー選択＝「最大密度（範囲ラベル・見出し最少）」。テスト追加（末尾畳み込み／孤立小月のパッキング）。
- 設定化: 密度（1セクションを閉じるまでに貯める**行数**）をユーザー設定にした。`GridSettingsKeys.monthSectionRows`（既定1）→ `PhotoGridView`→`PhotoCollectionView` で `coalesce = 列数 × 行数`。UI は General → 「Photo Grid」（細1行/ふつう3行/粗5行）。行数が大きいほど見出し（範囲ラベル）が減り粗く・密になる（写真の詰め自体は1行設定で既に最密で、Nはヘッダー頻度＝末尾半端行/見出し行の削減）。
- 残課題: プリセットは 1/3/5 の3段階。必要なら連続スライダー化や per-source 設定の余地。

## CI の iOS テストがコールドブートで間欠的に TEST FAILED
- 症状: GitHub Actions の `scripts/test.sh ios`（DropboxCore/PhotosFeatureKit を iOS Sim で実行）が回によって "TEST FAILED"。ローカルや一部の CI ランは成功。
- 原因: **シミュレータのコールドブートが遅い回（217〜258秒）だけ失敗**し、速い回（59秒）は成功。テスト本体ではなく、シミュレータ起動の遅延でテスト実行がタイムアウト気味になるフレーク（CI ランナーの負荷/初回ブート依存）。CI 全体は ios が `continue-on-error`（非ブロッキング）なので緑のままだが、ステップが赤く見えていた。
- 対処: `run_ios` で**テスト前に対象シミュレータを明示起動して暖機**（`simctl boot` ＋ `simctl bootstatus -b`）し、ブート時間をテスト実行から切り離す。さらに `xcodebuild test` に **`-retry-tests-on-failure -test-iterations 2`** を付け、遅延由来のフレークを吸収（失敗分のみ再試行）。
- 関連: `scripts/test.sh`（boot_sim/run_ios）、`.github/workflows/ci.yml`（ios は非ブロッキング）。
- 残課題: それでも極端に遅いランは起こり得る（best-effort のまま）。一部 DropboxCacheStore/SyncEngine テストが ~4.5s と重め＝必要なら短縮余地。

## オンデバイス CLIP モデル選定の認識率ベンチマーク
- 背景: 同梱 CLIP モデルの選定にあたり、出荷する Core ML モデルそのままで認識率を実測して比較した（`scripts/eval_recognition.sh`／`eval_recognition.py`）。
- 評価条件: ImageNet-1k 1000クラスのゼロショット分類（各クラス20枚＝200枚・top-1）＋自然文クエリ10件。CoreMLTools で **CPU 実行**（fp16 の不安定要因を排除した決定的比較）。Imagenette(val) を画像ソースに使用。
- 結果（top-1 / クエリ）:
  - MobileCLIP-S2（旧・モバイル最適化・参考）= **81.0%** / 10件満点（画像enc 68MB）
  - OpenCLIP ViT-B-16 / datacomp_xl = **75.0%** / 満点（画像enc 165MB・patch16＝約4倍重い）
  - **OpenCLIP ViT-B-32 / datacomp_xl（採用）= 75.0%** / 満点（画像enc ~60MB・patch32＝軽い）
  - OpenCLIP ViT-B-32 / openai = **64.5%** / 満点（~60MB）
- 採否: **ViT-B-32/datacomp を採用**。軽量（patch32・~60MB）ながら 75% を達成し、自然文クエリは満点。ViT-B-16 は同等精度だが画像推論が約4倍重く、67k 枚の背景埋め込み（電池/時間）と相性が悪いため見送り。openai 重みは精度が低い。
- 実装メモ: 変換は `scripts/convert_clip.py`（open_clip→Core ML・CLIP の mean/std を画像エンコーダ内に内包＝アプリ無改修・画像 fp16/テキスト fp32）。同梱ファイル名（`MobileCLIP*`）は互換のため据え置き（中身は OpenCLIP）。`MLImageConstraint` で自動リサイズ（imageSize 256→224 は config 経由）。モデル変更時は `perceptionVersion` を採番して全再埋め込み。
- 関連: `scripts/convert_clip.py` / `scripts/eval_recognition.*` / `scripts/build_mobileclip.sh` / `AutoAlbumEngine`(perceptionVersion)。選定の意思決定全体は [[ADR-19]]。
- 残課題: より精度の高い軽量モデルが出れば再ベンチ。200枚標本のためサンプル誤差あり（必要なら per-class を増やす）。

## 写真枚数に比例したメモリ枯渇（起動クラッシュ）
- 症状: 写真ゼロの端末では起動するが、写真が多い端末では起動前に落ちる。
- 原因: CLIP 埋め込み `clipVector`（512×fp32 ≈ 2KB/枚）を `PhotoEnrichment` に inline 格納。SwiftData は全件 fetch で行を丸ごと展開するため、`allEnrichedPhotosLite()` 等でも fetch 時点で 67k×2KB ≈ 138MB を確保し jetsam。複数経路の全件 fetch が起動直後に重なって悪化。
- 対処: 埋め込みを `PhotoEmbedding` 別テーブルへ分離（メタ fetch が blob に触れない）。Float16 で保存（2KB→1KB、読み出し時 fp32 復元）。検索はページング。大量 upsert は使い捨て `ModelContext` でチャンク save→解放。メモリ圧迫時は背景タグ付けを停止。スキーマは `AutoAlbumV10` で再構築。
- 関連: f84529c（本対応）、c08b287（前段: 検索のバッチ化）。`AutoAlbumStore.swift` / `PhotoEmbedding.swift` / `ClipMath.swift`。
- 残課題: 旧 V9 破棄により埋め込みは背景で再生成（精度は徐々に回復）。HTML 詳細あり。

## 起動が遅い・真っ白な待ち時間（高速化とローディング表示）
- 症状: 起動に時間がかかり、特にシミュレータで顕著。最初のフレームまで何も出ない。
- 原因: 各ストアが `init` で `ModelContainer` を同期構築し、`HomeView.init` がそれをまとめて行うため最初の描画をブロック。さらに起動直後に重い処理が同時実行されスパイク。
- 対処: `RootView` を新設し `HomeStores.build()` で非同期構築（合間に `Task.yield`）。1 秒超で「Now loading…」表示。バックグラウンド処理を段階起動（場所 +1.5s / AI +3s / バックアップ +5s）。
- 関連: 8bc97dd（非同期化・ローディング）、e8667e1・98369e1（スパイク対策・オフメイン化）。`RootView.swift` / `HomeView.swift`。
- 残課題: なし。HTML 詳細あり。

## 起動時 SwiftData クラッシュ＋キャッシュ二重オープン
- 症状: 実機でアプリ起動前に停止（解析ログにも残らない）。
- 原因: (A) `ModelContainer` 初期化がストア破損・スキーマ不整合で trap し、`fatalError` 相当で標準ハンドラを通らない。(B) Dropbox キャッシュのコンテナが二重に開かれていた。
- 対処: (A) `makeResilientContainer`（削除→再試行→インメモリ）で起動を止めない。(B) actor 経由に一本化。
- 関連: 7e53db3。`AutoAlbumStore.swift` / `DropboxCacheStore.swift` / `BackupEngine.swift`。
- 残課題: `fatalError`/SwiftData trap は端末診断ログに残らない（標準クラッシュログ側）。

## 実機で起動直後に落ちる（最小デプロイメントターゲット）
- 症状: 実機に入れると起動しない／インストールできない。
- 原因: `IPHONEOS_DEPLOYMENT_TARGET` が 26.5 になっており、端末 OS が下位だと不可。
- 対処: 26.0 へ引き下げ（Debug/Release 両方）。
- 関連: 736362b。`project.pbxproj`。
- 残課題: なし。

## サムネイルスクラバーが機能しない → UICollectionView 全面置換
- 症状: 右端スクラバーが動かない／大ジャンプで画面が止まる（特に Dropbox の大量グリッド）。
- 原因: (1) `enabled` トグルでスクロール subtree が再構築されジェスチャがキャンセル。(2) `onScrollGeometryChange` が `scrollTo` と競合。(3) 6.7 万件 `LazyVGrid` で `scrollTo(id)` が不安定。
- 対処: 段階的修正（R3 撤去・即時スクロール）後、根本解決として UICollectionView へ全面置換（contentOffset ベースのスクラバー、diffable、プリフェッチ）。
- 関連: 5b6c355 / 4320f41 / ef168d5 / 9897653。`PhotoCollectionView.swift` / `GridScrubberView.swift`。
- 残課題: なし。ADR-4 参照。

## サムネイルが横長・1 列になるレイアウト崩れ
- 症状: グリッドの各セルが極端に横長で 1 列しか入らない。
- 原因: `CompositionalLayout` の `repeatingSubitem:count:` が item の `fractionalWidth(1)` を尊重して 1 列化。
- 対処: `subitems:[item]` に変更し、item 幅を `fractionalWidth(1/cols)` ＋ `contentInsets` で指定。
- 関連: 8931bb3。`PhotoCollectionView.swift`。
- 残課題: なし。

## CLIP 画像埋め込みが遅い（fp32 で ANE 非対応）
- 症状: 実機ログで背景の CLIP 画像埋め込みが 8 枚バッチあたり 4〜10 秒（≒1 枚 0.5〜1.3 秒）。数百枚で 7〜15 分かかる。
- 原因: 画像エンコーダを `compute_precision=FLOAT32` で Core ML 変換していた（元はシミュレータの NaN 回避目的）。実機の Neural Engine(ANE) は fp16 前提のため、fp32 モデルは ANE に載らず GPU/CPU フォールバック＝遅い。
- 対処: `convert_mobileclip.py` の画像エンコーダを `FLOAT16` に変更（ANE 対応）。fp16 はシミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落とすため安全に無効化される。画像タワー依存テストはシミュレータでスキップし実機検証へ。
- 関連: `scripts/convert_mobileclip.py`、`MobileCLIPRuntime`、`MosaicPhotosTests/ImageRecognitionTests.swift`。ADR-11。
- 検証: 認識率ハーネス（`scripts/eval_recognition.sh`）で fp16 Core ML モデルを評価。Imagenette 画像に対し、(1) 10クラス zero-shot=**100/100**、(2) **1000クラス**(ImageNet-1k) zero-shot=**84/100**（誤りは English springer→Welsh Springer Spaniel 等の細分類で妥当）、(3) **自然文クエリ retrieval**（クラス名を言わない自由文10件）=**10/10**。fp16 化による認識率劣化は見られない。※ macOS CPU_ONLY では一部画像埋め込みが fp16 で数値不安定（ツール側で非有限を除外）。実機(ANE)の速度・精度は再解析で別途確認。

## All サムネイルビュー（68k）が遅い（スナップショット構築がメインスレッド）
- 症状: 端末＋Dropbox 統合の All ビュー（約68,512件）が表示・ピンチで重い。
- 計測（`Diagnostics.mark`）: `merged.rebuild`（merge+sort・オフメイン）=144ms で問題なし。一方 `grid.snapshot`（`PhotoCollectionView.applySnapshot`・**メインスレッド**）= **build 901ms / total 1014ms**（id→index 208ms 含む・135セクション）。ピンチ/モード変更のたびに 485〜950ms を**繰り返し**発生。footprint 156〜246MB。
- 原因: `applySnapshot`（id→index 構築・グルーピング・NSDiffableDataSourceSnapshot 構築・reloadData）が全部メインで走り UI を固める。さらにシグネチャに列数を含めていたためピンチ（列変更）で毎回フル再構築。先日の密表示で coalesce を列数依存にしたのも再構築を誘発。
- 対処: (A) 重い構築（id→index・グルーピング・snapshot 構築）を `Task.detached` で**オフメイン**化し、メインは `applySnapshotUsingReloadData` と参照テーブル代入のみ（世代トークンで古い構築を破棄）。(B) シグネチャから列数を外し、**列変更はレイアウト作り直しのみ**で再スナップショットしない。coalesce を列数非依存の固定値（4）に。
- 関連: `PhotoCollectionView.swift`、`PhotoGridGrouping.swift`。Swift5 モードのため非 Sendable（snapshot）のクロージャ越え捕捉は許容。
- 学び: 大規模 diffable は **snapshot をバックグラウンドで構築 → メインで apply** が定石。UI を固める純データ構築は main で回さない。

## All ビューの Dropbox サムネイルが「ポツポツ」1 枚ずつ遅く出る（先読みの直列 await）
- 症状: All サムネイルビューで Dropbox 写真のサムネイルが 1 枚ずつポツポツ現れ、表示が非常に遅い。スナップショットのオフメイン化（前項）後も改善せず。
- 原因: `DropboxPhotoStore` が `prefetch` を上書きしておらず、`PhotoLoading` の**既定実装**（`for item in items { await thumbnail(...) }` の**直列 await**）を使っていた。1 枚ごとにネットワーク往復を待ってから次を要求するため、`DropboxThumbnailBatcher` のバッチ集約（25 枚/リクエスト）・並行取得（最大 8 本）が完全に殺され、実質「バッチサイズ 1・直列」で取得していた。
- 対処: `DropboxPhotoStore.prefetch(_:targetSize:)` を上書きし、各 item を**並行発火**（`Task { await thumbnail(...) }`）してバッチャの `pendingItems` にまとめて積ませる。バッチャが 25 枚チャンク×最大 8 並行で一括取得し先読み窓が一気に埋まる。キャッシュ確認（メモリ→ディスク）は `thumbnail(for:)` 内で行われるためディスクヒット分はネットワーク不要。`MergedPhotoStore.prefetch` は local/cloud を振り分け、cloud をこの並行先読みへ流す。
- 関連: `DropboxPhotoStore.swift`（prefetch 上書き）、`PhotoLoading.swift`（既定の直列実装）、`DropboxThumbnailBatcher.swift`、`MergedPhotoStore.swift`。
- 学び: バッチ集約するローダに対し「1 件取得を `await` で直列に並べる」既定先読みは集約・並行を無効化する。バッチ系ソースは先読みを**並行発火**してローダ側に集約させる。

## メモリ常駐の圧縮（NSCache のコスト計算ズレ・フル解像度デコード・配列常駐）
- 症状: 写真の多い環境でメモリ常駐が高く（実機 footprint 150〜250MB）、圧迫しやすい。CLIP 埋め込みの別テーブル化（ADR-6）後も残るメモリ消費を更に圧縮したい。
- 原因（精査で判明した複数）:
  1. **NSCache のコスト計算ズレ（最大要因）**: サムネイルのメモリ層は**デコード済み画像**を入れているのにコストを **JPEG バイト数**（約20KB）で計上していた。`totalCostLimit=100MB` は JPEG 換算なので、実デコード（1枚 0.3〜2.4MB）では**約10倍以上＝〜1GB 相当**まで保持し得た（写真比例の圧迫の主因）。
  2. **グリッドサムネイルが端末スケール（×3）のフル解像度**。サムネイルに ×3 は不要。さらにピンチで列数が変わるたび僅差サイズのキーで重複デコードが増えていた。
  3. **ビューアのフル画像がフル解像度デコード**。ローカルは `PHImageManagerMaximumSize`（1枚 40MB 超）、Dropbox はキャッシュ済み JPEG をフルデコード。ページャの前後保持でピークが跳ねる（ビューアはピンチズーム無し＝`scaledToFit` 表示なのでフル解像度は不要）。
  4. **表示用アイテム配列に不要文字列が常駐**: `DropboxFileItem.contentHash`（64桁hex）を 67k 件分メモリ保持。表示では debug 表示しか使わない。
- 対処:
  1. `MemoryImageCache.insertDecoded`／`decodedCost`（幅px×高px×4）を新設し、ローカル `ThumbnailCache`・Dropbox `thumbnailMemory` を**実コスト計上**に。Dropbox は `totalCostLimit=48MB` を併設。メモリ警告（`didReceiveMemoryWarning`）で全消去するオブザーバも `MemoryImageCache` に追加。
  2. `PhotoCollectionView.cellPixelSize` を **×2 上限**＋**64px バケット量子化**（1アセット1サイズに寄せ重複を抑制）。ローカル fallback も ×2 上限。
  3. `ImageCacheKit.ImageDownsampling`（ImageIO `CGImageSourceCreateThumbnailAtIndex`・最大辺 2048）を新設し、ローカル fullImage は 2048 境界要求、Dropbox fullImage はダウンロード／キャッシュ両経路でダウンサンプル（保存は原バイトのまま＝EXIF 保持）。
  4. `DropboxCacheStore.cachedItems()` の表示アイテム生成で **contentHash を渡さない**（同期の変更検知は `CachedDropboxItem`＋delta parser が担うため不要）。
- 関連: `ImageCacheKit/MemoryImageCache.swift`・`ImageDownsampling.swift`／`LocalPhotoCore/ThumbnailCache.swift`・`LocalPhotoStore+PhotoStore.swift`／`DropboxCore/DropboxCacheStore.swift`・`+Binary.swift`・`DropboxPhotoStore.swift`／`PhotoSourceKit/PhotoCollectionView.swift`。ADR-6（埋め込み別テーブル）の続き。
- 学び: **NSCache のコストは実バックストア（デコード後バイト）で計上する**。JPEG バイトで計上すると上限が桁で狂う。ズーム無しビューアはフル解像度をデコードしない（ImageIO ダウンサンプルでピーク削減）。長寿命の大規模配列には表示に使わない文字列を載せない。
- 追補（上限のチューニング）: ローカルサムネのメモリ上限の既定を **Auto**（`ThumbnailMemoryBudget`＝物理 RAM の約1.5%・40〜120MB クランプ）にし、選択肢に 60MB を追加（`CacheSettingsKeys.memoryLimitMB` の **0=Auto**）。フル画像の最大辺を **2048→1600**（約36%減）。`MemoryImageCache` のメモリ警告応答を**全消去→段階縮小**（上限を一時的に半分・下限16MB、30秒後に復帰。`configuredCostLimit` を保持し圧迫中の `setTotalCostLimit` は復帰時に反映）に変更し、直近サムネを残して再デコードを抑える。関連: `ThumbnailMemoryBudget.swift` / `LocalPhotoSettingsView.swift` / `ImageDownsampling.swift` / `MemoryImageCache.swift`。

## フォルダ名アルバムが動かない（正規表現を写真ごとに再コンパイル）
- 症状: フォルダ名アルバムの日付抽出を入れた後、生成が事実上停止し「動かない」。
- 原因: `FolderDateParser`（約10パターン）と `PathAlbumNamer`（ルール）が **写真1枚ごとに `NSRegularExpression` を毎回コンパイル**。Dropbox 67,639 枚 ×（10＋ルール数）で数十万回のコンパイルになり生成が終わらない。
- 対処: (1) 両者の正規表現を `NSCache` で**コンパイル結果をキャッシュ**（スレッドセーフ）。(2) `PathAlbumStrategy` で**日付解析をフォルダ単位にメモ化**（写真ごとに再解析しない）。これで解析回数は「フォルダ数」程度に激減。
- 関連: `FolderDateParser.swift` / `PathAlbumNamer.swift` / `PathAlbumStrategy.swift`。ADR-13。
- 学び: 大量データ（数万件）を回す純ロジックでは、`NSRegularExpression` の**コンパイルをループ内で繰り返さない**（事前コンパイル/キャッシュ）。入力単位（フォルダ等）でのメモ化も併用する。
- **真因（診断ログで確定）**: 上記の後も空のままで、ログ `pathAlbum.fast: enabled=true rules=1 provider=true / metas=0` から判明。`generateFast`（↻ボタン）が `cloudProvider.cloudPhotos()`＝`dropboxStore.items` を読むが、items は **All Photos/Cloud を開くまで読み込まれない**ため起動直後は 0 件 → 生成 0、さらに `replaceAlbums([])` で**既存フォルダアルバムを消す**二次被害。対処: `DropboxCloudPhotoProvider.cloudPhotos()` を「items が空ならキャッシュから `loadItems()` してから返す」自己完結型に修正（クラウドのエンリッチ・署名計算にも効く）。学び: **UI ナビゲーション依存の状態（store.items）を、UI 前に走る生成ロジックの入力にしない**（必要時に自分でロードする）。診断ログの威力＝推測でなく一行で確定。

## AI アルバムに何も入らなくなった（FM の OR 出力が過剰なハード条件を生成）
- 症状: 合成可能検索（QuerySpec/OR）導入後、どの AI アルバムにも写真が入らなくなった。
- 原因: Foundation Models の新スキーマ `GeneratedSpec` が「子供」等の内容を `peopleAtLeast`/`people`/`hasLocation` などの**ハード条件**として出力し、People インデックスや位置情報を持たない写真を全除外 → ハード絞り込み後の base が空。内容で表すべき語をハード化したのが主因。
- 対処（最終）: (1) FM スキーマから **peopleAtLeast / hasLocation を廃止**（人物の有無・概念は内容=ソフトで扱う）、日付は妥当範囲のみ採用（`sanitizedDate`）。(2) `AIAlbumSearcher` に **安全網**＝ハードで base が全滅しても意味の意図があれば内容のみへ緩和（緩和時ヒット0は空＝全件は出さない）。これで OR を維持したまま全滅を防ぐ。相対日付（RelativeDateParser）も維持。
- 補足: 切り分け用に `Diagnostics.mark` を `AIAlbumSearcher`（base/scored/top/kept/relaxed/result）と `AIAlbumService`（make/refresh の件数）に追加。なお**シミュレータでは fp16 画像エンコーダが NaN 化し CLIP 検索は空が正常**（実機 ANE 前提・ADR-11）。
- 関連: `FoundationModelsQueryUnderstanding.swift`、`AIAlbumSearch.swift`、`AIAlbumService.swift`。ADR-12。
- 学び: LLM 由来の構造化条件は**ハード化すると簡単に全滅する**。内容（人物の有無・概念）は原則ソフト(CLIP)で扱い、ハードは「データが確実に持つ」属性（日付/地名/お気に入り等）に限定し、加えて全滅時の緩和フォールバックを用意する。

## 認識率の深掘り：cassette player が 1000-way で弱い理由
- 症状: 1000クラス zero-shot で `cassette player` だけ top-1=34.7%（300枚中104）と突出して低い。
- 分析: 認識率ハーネスに `confusion` モードを追加して調査。**top-5=92.3%・正解ラベルの順位は中央値2**。誤判定先はすべて酷似機器（CD player 87 / tape player 39 / radio 25 / entertainment center / cassette …）。
- 結論: 「オーディオ機器」とは正しく認識できており、cassette/CD/tape の<strong>細分類を top-1 で当てられないだけ</strong>。ImageNet 既知の曖昧クラスでありモデル欠陥ではない。さらに**本アプリは 1000-way 分類をしない**（実機能は語彙ゼロのオープン語彙検索＝クエリ評価10/10、と約300語の表示タグ）ため、この弱さは実利用にほぼ影響しない。
- 示唆: 表示タグ（約300語）では「cassette player / CD player」のような区別の難しい近接語よりも、上位概念（"audio player" 等）を採るほうが頑健。
- 関連: `scripts/eval_recognition.py`（`--mode confusion --focus-wnid`）。単一プロンプト計測のため、80テンプレ平均にすると数pt改善余地あり。

## 67,639 件の Dropbox キャッシュを画面表示ごとに全リロード
- 症状: 実機ログで All Photos を開くたびに `loadItems() — 67639 items` が走り、SwiftData から 67k 件を毎回実体化していた。
- 原因: `MergedPhotoStore.start()` が無条件で `dropboxStore.loadItems()` を呼んでいた（Dropbox 側 `start()` にはあった「既ロードならスキップ」ガードが Merged 側に無かった）。
- 対処: 既ロード時はスキップするガードを追加。同期増分は `scheduleCacheRefresh→items 更新→observeStores` の再ビルドで反映されるため取りこぼし無し。
- 関連: `MergedPhotoStore.start()`。コミット 0430c1a。

## アルバムを開いて戻ると無関係な写真になる
- 症状: 子アルバム → Dropbox サムネで過去写真を見る → 戻ると別アルバムの中身が表示される。
- 原因: 複数の `.fullScreenCover(item:)` / `.sheet(item:)` を併用し、提示competitionで対象が入れ替わる。
- 対処: 遷移先を単一の `HomeDestination` enum＋1 つの `.fullScreenCover` に統合（`.sheet` も統合）。
- 関連: `HomeView.swift`（コミット履歴参照）。ADR-5。
- 残課題: なし。

## 画面遷移のパフォーマンス計測点を追加（PerfTrace 拡張）
- 症状: 画面遷移（ホーム→各画面、グリッド→フル写真、設定シート）が場面によって重い。どこで時間がかかるかを実機で測りたい。
- 原因: 既存 `PerfTrace` は Dropbox の通信/キャッシュ/デコードしか計測しておらず、遷移の所要を出す手段がなかった。
- 対処: `PerfTrace` に**画面遷移計測 API** `beginScreen(name)`/`endScreen(name)` を追加（name キーで開始時刻を保持→遷移先の onAppear で所要 ms を `screen.*` としてログ／signpost）。SwiftUI からは `View.perfScreenEnd(_:)`（PhotoSourceKit）で遷移先に付与。計測点:
  - `home.present`＝ホームのタップ（`destination` セット）→ フルスクリーン表示の onAppear。
  - `home.settings`＝設定シートを開く所要。
  - `open.photo`＝グリッドのセルタップ → `PhotoPageView` の onAppear。
  - `grid.<title>`＝ソース画面の onAppear → 初回コンテンツ（loaded/empty/failed）確定まで。
  - 既定無効（オーバーヘッドなし）。Developer Options の「Performance tracing」トグル（`AppSettingsKeys.perfTracing`）で ON、再現、OFF。ログは Diagnostics log で閲覧・共有。
- 関連: `PerfTrace.swift`(beginScreen/endScreen) / `PerfScreen.swift`(perfScreenEnd) / `PhotoGridView.swift` / `PhotoSourceContentView.swift` / `HomeView.swift` / `DeveloperSettingsView.swift`。
- 残課題: ソース画面がキャッシュ済みで onAppear 時点ですでに loaded の場合、状態変化が起きず `grid.<title>` の end が出ない（瞬時＝重くないケースなので実害なし）。

## 画面遷移が最大14.6秒：背景CLIPのCPU占有が主因（＋場所表示の get_metadata 回帰）
- 症状: PerfTrace の実機(シミュレータ)ログで `screen.open.photo`（写真タップ→フル表示）が通常 ~100ms のところ **11.4s / 14.6s** に膨張。同時にサムネの `decodeMs` が単発 20.8s、`net.get_thumbnail_batch` が 14〜15s に膨れる。
- 原因:
  - **主因＝背景 CLIP タガーの CPU 占有**。ログに `[Tagger] embed: batch 4 done — 8 photos in 91.7s`。シミュレータは CLIP を `.cpuOnly` で実行するため 1 枚 ~11s かかり全 CPU を食い潰す。その間メインスレッドが遷移コミットを走らせられず `open.photo` が膨張、デコード・ネット継続も巻き添えで膨れる。タガーの停止判定は **8枚バッチの合間だけ**で、一度始まると最悪 91s 譲らない。譲り条件も「スクラブ／メモリ圧迫／クラウドサムネ中」のみで**フル画像取得・写真閲覧・遷移は対象外**だった。
  - **回帰＝場所表示**。今回追加した「日付の下に地名」が `PhotoPageView` で毎ページ `location(for:)` を呼び、クラウド写真は座標未キャッシュ時に **get_metadata（4〜6s）をその場で叩いて**いた（非同期なので open.photo は膨らまないが無駄な往復＋競合）。
  - ※ 11〜14s は**シミュレータ特有の増幅**（実機は ANE=`.all` で CLIP が速く CPU を空ける）。ただし構造的問題（停止粒度の粗さ・譲り条件の不足・回帰）は実機にも効くので是正。
- 対処（A〜E）:
  - A: タガーの**停止判定を 1 枚単位**に（`perceive` を 1 枚ずつ・各推論前に `shouldPause`）。譲り条件に **`fullImageBusy`**（`DropboxActivityMonitor.beginFullImage`→`BackgroundActivityMonitor` 橋渡し）と **`isViewingPhoto`**（タップ時=グリッド `onSelect`／フル表示 `onAppear` で true、グリッド復帰・`onDisappear` で false）を追加。
  - B: **シミュレータでは背景埋め込みをスキップ**（`#if targetEnvironment(simulator)` 早期 return・実機は不変）。
  - C: 場所ラベルは **`cachedLocation(for:)`**（ネット取得を伴わない＝Dropbox は座標キャッシュのみ・get_metadata を叩かない）を新設し `PhotoPageView` をそれに切替。開くたびの 4〜6s 往復を解消。
  - D: フル画像の体感改善＝**隣接ページの先読み**（`prefetchFullImage`・クラウドはバイトのみ取得保存・デコードなし）＋**ロード中はサムネをぼかして先出し**（`FullPhotoView`、黒画面待ちを軽減）。
  - E: **longpoll を専用 URLSession に隔離**（`URLSession.dropboxLongpoll`／`DropboxAPIClient.longpollClient`）。longpoll は別ホスト（notify）なので競合影響は限定的だが、30〜50s 保持の接続を共有セッションのスケジューリングから切り離す保険。
- 関連: `PhotoTagger.swift`（1枚単位＋simulator skip）/ `AutoAlbumEngine+Recognition.swift`（shouldPause）/ `BackgroundActivityMonitor`（fullImageBusy・isViewingPhoto）/ `DropboxActivityMonitor`（橋渡し）/ `PhotoLoading`（cachedLocation・prefetchFullImage）/ `DropboxPhotoStore`・`MergedPhotoStore`（上書き）/ `PhotoPageView`・`PhotoGridView`・`FullPhotoView` / `HTTPClient`・`DropboxAPIClient`（longpoll 分離）。
- 残課題: 効果は**実機**で再計測（シミュレータは B で背景埋め込みが止まる＝主因が出ない）。クラウドフル画像の download 6〜9s はネット律速で別途。E の効果は小さい見込み（別ホスト）。
- 追補（再計測で仮説が外れた→真因はサムネの嵐）: A〜E 適用後の再計測で**タガーのログは消えた（B 有効）が `screen.open.photo` は依然 14s**。CLIP は主因ではなかった。真因は**クラウドのサムネ取得＋デコードの嵐**：`thumb-drain` の `missWaitMs=271(Σ14.7M ms＝1枚平均~54s 待ち)`、`net.get_thumbnail_batch` が 170KB で **20〜22s**、HEIC `decodeMs` が **1.78s/枚**。多数の並行デコード（`.userInitiated`）と先読みが CPU/帯域を飽和させ、URLSession の継続再開もメインスレッドの遷移コミットも飢餓 → onAppear が 14s 遅延。さらに **D（フル画像先読み）が逆効果**で、タップした画像(1.5MB)と同時に先読みの隣2枚(1.8/2.7MB)を並行 DL し可視画像を遅くしていた。※ 20s/170KB＝8KB/s や 1.78s デコードは**シミュレータの遅さ**が大きい（実機は HW デコード＋実回線で桁違いに速い）。
  - 追加対処: (1) **フル写真表示中は先読みドレインを止める**（`DropboxThumbnailBatcher.nextWave` が `BackgroundActivityMonitor.isViewingPhoto` 時は可視のみ処理）＝取得スロット/帯域/CPU を遷移とフル画像に明け渡す。(2) **D を「次の1枚だけ・1.2s 遅延・同ページ維持時のみ」**に縮小（可視画像を先に通す）。(3) **ネット応答デコードを `.userInitiated`→`.utility`** に下げ、メイン/遷移を飢餓させない。
  - なお残る 14s 級の多くはシミュレータのネット/デコードの遅さ由来。**実機で再計測**が前提。
- 追補2（真の主因＝6.7万件 TabView の一括構築）: ログ量を増やして再計測したところ決定的な手掛かり＝`MARK grid.snapshot: items=67639`（All Photos 統合グリッド 6.7万件）。`PhotoPageView` がタップのたびに `TabView { ForEach(store.items) }` を **67,639 ページぶん一括構築**していた（`.page` スタイルの `TabView` は遅延生成されないため）。これがタップ→`onAppear` を 11〜14s 固める主因（CLIP・ネットではなく**ページ構築**）。`store.items`（MergedPhotoStore）は O(1)＝再マージではない点も確認。
  - 対処: **ウィンドウ方式**に変更。現在 index の前後 `windowRadius=30`（最大61ページ）だけを `TabView` に渡し、端から 8 枚以内に近づいたら現在 index 中心へウィンドウを寄せ直す（`windowLowerBound` を更新）。選択中 `currentID` は常にウィンドウ内なので表示中の写真は維持。6.7万→最大61 で構築コストを定数化。
  - 計測強化: 切り分け用に `open.construct`（タップ→`PhotoPageView.init`）と `open.render`（init→`onAppear`＝ページ構築＋遷移）に分割計測を追加。次回ログで `open.render` が小さくなれば本対処が効いたと確認できる。
  - 関連: `PhotoPageView.swift`（windowItems / recenterWindowIfNeeded / 計測分割）/ `PhotoGridView.swift`（open.construct begin）。

## サムネのメモリ上限・デコード並列を端末資源から決める（固定値→予算連動）
- 背景: v0.16 の実機ログで、サムネのキャッシュヒットが遅い（`thumb-drain`: `diskHit=3344 Σ2.59M ms＝平均775ms/枚`、`missWaitMs Σ4.27M ms＝平均2.7s/枚`）。`memHit=1564` に対し `diskHit=3344`＝メモリキャッシュが小さく 2/3 が遅いディスク再デコードに回り、`diskHit` の大半は**デコードセマフォの順番待ち**（計測 t0 が acquire 前＝待ち込み）。デコード自体は ~36ms と速い。あわせて footprint が 237→**427MB**（フォルダアルバム生成）→385→280MB とスパイク。
- 着眼（ユーザー指摘）: 「パラメータを固定で持つより CPU/メモリから決めた方がよいのでは？」。整理すると、**メモリ系上限＝端末メモリ予算から決めるべき**（固定80MBは低RAMでjetsam・高RAMで取りこぼし）、**CPU並列＝既にコア数連動**、**ネット並行＝資源でなくDropboxレート制限で決まるので固定**、が妥当。
- 対処:
  - `MosaicSupport.MemoryBudget` を追加。予算は **`os_proc_available_memory()`**（iOS 13+・kill されるまでの実バイト。physicalMemory より正直）、取得不可/他OSは physicalMemory の一部。`thumbnailCostLimit(budget:)`＝予算の約5%を **60〜192MB にクランプ**（純関数・テスト対象、`override` でDI可）。
  - `DropboxInternalConstants` のサムネメモリ上限/件数/圧迫下限を**この予算算出に置換**（件数≈cost/64KB、下限=cost/2）。ベース＝予算連動／反応＝`MemoryPressureMonitor` の動的縮小、の**二段構え**。
  - ディスクデコード並列 `thumbnailDecodeConcurrency` を `max(4,コア)`→**`max(6,コア×2)`** に引き上げ、diskHit の順番待ち行列を浅くする（デコードは軽いので低リスク）。
  - **ネット並行は固定のまま**（CPU/メモリ連動にすると速い端末ほど429を食う筋違いになる）。
- 関連: `MosaicSupport/MemoryBudget.swift`（+テスト）/ `DropboxInternalConstants`（予算連動・並列係数）/ `MemoryImageCache`（圧迫縮小は既存）。
- 残課題: 効果は v0.17 実機で再計測（diskHit/missWait・memHit比・footprint）。フォルダアルバム生成の 427MB スパイク（`allEnrichedPhotosLite()` 全件一括）はページング化が別途の課題。`maxPrefetchBacklog`(600) も予算連動の余地。

## フォルダアルバム生成のメモリスパイク（@ModelActor 長命 context の全件 materialize）
- 症状: 実機ログで `pathAlbum.full: enriched=85304 → albums=217 (footprint=427MB)`。フォルダ/自動アルバム生成時にメモリが大きくスパイク。
- 原因: `AutoAlbumStore`（@ModelActor）の**長命 modelContext** が、`prune()`（全件 fetch）・`refreshLocalLinkKeys()`（local 全件 fetch）・`allEnrichedPhotosLite()`（全件 fetch）で **8.5万件の `PhotoEnrichment` @Model を materialize** し、save 後も登録が残って積み上がる。トリップ分割自体は全件の値型が必要だが、値型（`EnrichedPhoto`・軽量）ではなく @Model の materialize がピークの主因。
- 対処（R4・部分）: 読み取り専用の `allEnrichedPhotosLite()` を**使い捨て ModelContext でページ fetch→値型化→破棄**（5,000件/ページ）に変更し、materialize を 1 ページに有界化。直前の prune/更新を見るよう save 済みにしてから読む。蓄積は軽量値型のみ。
- 関連: `AutoAlbumStore.allEnrichedPhotosLite`。
- 残課題（follow-up・要実機検証）: 支配的なのは `prune()`/`refreshLocalLinkKeys()` の全件 materialize。バッチ削除（`delete(model:where:)`）化や使い捨て context への移行で更にピークを下げられるが、67k 要素 predicate の IN 句や書き込み context の整合（長命 context の stale 化）に踏み込むため、**実機メモリ計測込みで別途**対応する（ブラインドで書き込み経路を変えない方針）。

## ピープルが空＝PhotoKit に公開 People API が無い／顔クラスタリングへ作り直し
- 症状: ホームの「ピープル」に人物が出ない。
- 原因: `PeopleScanner`／backup の people インデックスが `fetchAssetCollections(with: .album, subtype: PHAssetCollectionSubtype(rawValue: 1000))`（コメントは「albumFaces」）で取得していたが、これは誤り。album サブタイプの顔は `albumSyncedFaces = 4`（Mac の iPhoto/Aperture から同期した旧 Faces 専用・現存ほぼ無し）で、**現代の「ピープル」（端末ML が作る名前付き人物）はプライバシー保護のため公開 PhotoKit API では一切アクセスできない**。`rawValue 1000` はどの正規サブタイプにも該当せず、fetch は常に空 → 人が出ない。
- 対処（方針）: 公開 API で取れないため、**Vision で顔検出＋同梱 Core ML 顔認識モデル（権利フリー MobileFaceNet/ArcFace）で identity 埋め込み→逐次クラスタリング**する独自ピープルへ作り直す（ユーザー選択＝方式2・精度優先）。全オンデバイス・通信なし。旧 subtype-1000 経路は撤去予定。
- フェーズ: (1)**済** クラスタリングのコア（`FaceClustering`・コサイン逐次クラスタ・純ロジック＋テスト）と seam（`FacePerceptionProvider` / `DetectedFaceSignal`）を AutoAlbumCore に追加。(2) 顔モデル変換スクリプト（`scripts/` ・CLIP と同流儀で gitignore 同梱）。(3) Vision 顔検出＋Core ML 埋め込みの実体（MobileCLIPKit）。(4) 永続層（`DetectedFace` @Model・ModelConfiguration 採番）＋背景パイプライン（CLIP タガー同様のスロットリング）。(5) UI 差し替え（ホーム「ピープル」＝顔クラスタ・アバターは顔切り抜き）＋命名。(6) 旧経路撤去。
- 関連: `AutoAlbumCore/Faces/FaceClustering.swift`・`FaceSeams.swift`（+テスト）/ 旧 `LocalPhotoCore/PeopleScanner.swift`・`BackupKit/BackupIndexing.buildPeopleIndex`（撤去対象）。
- 残課題: 顔モデルは権利フリー（MIT/Apache）を選定・Core ML 変換。クラスタしきい値はモデル依存で実機調整。命名 UI・永続化。メモリ/電池はタガーと同じ譲り機構に乗せる。

### 追補（実装完了・全フェーズ）
顔クラスタリング版ピープルを完成させた（方式2・顔モデル同梱）。
- モデル: **facenet-pytorch InceptionResnetV1 / VGGFace2（MIT・512次元L2正規化）**。`scripts/build_facenet.sh`＋`convert_facenet.py`（[0,1] 入力・fixed_image_standardization 内包・FLOAT16）で `MosaicPhotos/FaceModel/` へ生成（.gitignore）。
- 永続: `FaceStore`（@ModelActor・**別コンテナ "FacesV1"**）＝CLIP 側（AutoAlbumV10）を壊さず追加。`DetectedFace`/`PersonCluster`（sum/count/代表顔）/`ScannedPhoto`（マーカー）。
- 背景: `FaceTagger`（PhotoTagger と同じ小バッチ＋休止＋shouldPause〔メモリ/閲覧/電源〕＋simulator スキップ）。検出は Vision、埋め込みは `FaceModelRuntime`（MobileCLIPKit）。
- クラスタ: `FaceClustering`（純・コサイン逐次・seed 復元で増分）。`PeopleEngine`（@MainActor @Observable）が `people: [PersonInfo]` を提供。
- UI: ホーム「ピープル」を顔クラスタに差し替え（アバターは代表顔 bbox の切り抜き＝`loadFaceAvatar`）。候補 refKey はアプリが PHAsset 列挙（端末写真のみ）。顔モデル未同梱なら非表示。
- 撤去: 旧 `PeopleScanner`/`PersonAlbumInfo`（subtype-1000）。
- 検証: アプリ iOS ビルド成功 / AutoAlbumCore 92テスト通過。※ 実機で顔モデル同梱→クラスタ精度としきい値（既定0.45）を要調整。命名 UI は今後（現状 "Person N"）。

## 設定画面のパラメータ増殖で peopleEngine の渡し忘れ（呼び出し側2箇所の不整合）
- 症状: ソース画面（All/Photos/Cloud 等）から開いた設定 → Developer Options に「Reset people」ボタンが出ない。ホームから開いた設定では出る。
- 原因: `SettingsView` の引数がエンジン追加のたびに増えて6個（auth/store/backup/place/autoAlbum/people）になり、呼び出し側が HomeView と SourceHostView の2箇所あるため、後から足した `peopleEngine`（optional・default nil）を SourceHostView 側に渡し忘れた。optional＋デフォルト引数のため**コンパイルエラーにならず**静かに機能が欠けた。
- 対処: 個別引数をやめ、既存の `HomeStores`（ストア一式のコンテナ）をそのまま渡す形に集約（SettingsView / DeveloperSettingsView / SourceHostView）。既存 body は computed の別名で差分最小。今後エンジンが増えても呼び出し側の変更が不要。
- 関連: リファクタ R9。`SettingsView.swift` / `DeveloperSettingsView.swift` / `SourceHostView.swift` / `HomeView.swift`。
- 残課題: 下位ビュー（StorageSettingsView 等）は optional 引数のまま（プレビュー用途）。増えるようなら同様に集約する。

## 顔の付け替えで重心演算が assign と不整合（正規化規則のズレ）
- 症状: （潜在バグ・実害が顕在化する前に発見）「この人は別の人」で顔を付け替えるたびにクラスタ重心がわずかに歪み、繰り返すと同一人物の判定が劣化し得る。
- 原因: 逐次クラスタリング `FaceClustering.assign` は埋め込みを**L2 正規化してから** sum に加算するのに、`FaceStore.reassignFace` の加減算は Float16 復元した**生ベクトル**を直接足し引きしていた。演算が2箇所に分かれ、規則（正規化）が片方にしか無かった。
- 対処: 付け替え用の重心演算を `FaceClustering.adding/removing`（純関数・assign と同じ正規化規則）に一元化し、`FaceStore` は fetch/persist に徹する。add→remove の往復で重心が元に戻ること・最後の1顔で nil（クラスタ削除の合図）・次元不一致でも count が顔数と整合することをテストで固定。
- 関連: リファクタ R11+R6。`FaceClustering.swift` / `FaceStore.swift` / `FaceClusteringTests.swift`。
- 残課題: 既存データで生ベクトル加減算により歪んだ重心は、ピープルのリセット（再スキャン）で再構築される。

## サムネイルが高品質まで空白＋デコード直列化（プログレッシブ表示への転換）
- 症状: グリッドの高速スクロール・ピンチズーム直後にセルが空白のままになり、反応が鈍く感じる。
- 原因: 3 点の複合。(1) PHImageManager のオプションは opportunistic なのに、requestThumbnail が degraded（低解像度プレビュー）を**意図的に捨てて**高品質コールバックまで待っていた＝それまでセルは空白。(2) ローカル ThumbnailCache（actor）が get/set 内で JPEG デコード・エンコードまで行っており、**全セルの読み込みが actor で 1 本に直列化**（Dropbox 側で既に解決済みの問題と同型）。(3) キャッシュキーがサイズ付きのため、ズームで列数が変わると全セルがキャッシュミス。
- 対処: `PhotoThumbnailing.thumbnailStages`（AsyncStream・既定は単発）を追加し、セルは届いた順に差し替えるプログレッシブ表示に。ローカル実装は「キャッシュ→別サイズの暫定表示（lastKeyByAsset 索引）→ degraded → 高品質」の順に流す。デコードは actor 外＋AsyncSemaphore（max(6, コア数×2)）で並列化し、actor は I/O とメモリ層のみに。先読みは `allowsCachingHighQualityImages = false` で fast 品質に限定。効果は PerfTrace カウンタ（thumb.hit/miss/nearSize/degradedFirst）で実測可能。
- 関連: パフォーマンスチューニング一式（R1+R2+R3/F1+F2/F3/S1-S3）。`PhotoLoading.swift` / `GridThumbnailCell.swift` / `ThumbnailCache.swift` / `LocalPhotoStore+PhotoStore.swift`。
- 残課題: Dropbox サムネイルの 2 段階化（現状は単発）。実機での hit/miss 比の確認としきい値調整。

## メインスレッドでの PHAsset 全列挙（デフォルト MainActor の罠）
- 症状: 起動直後・ソース画面を開くたびに UI が一瞬固まる。
- 原因: ビルド設定 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` により、**アプリ層の top-level 関数も暗黙 MainActor** になる。PeopleSupport の refKey 列挙（顔スキャン候補・お気に入り集合）と LocalPhotoStore.loadAssets が、数万件の fetch+enumerate（+sort）をメインスレッドで実行していた。PlaceScanner や PhotoEnricher は Task.detached 済みだったが、最も頻繁に通る 2 経路が漏れていた。
- 対処: いずれも Task.detached（utility/userInitiated）へ移し、メインは完成配列の代入のみに。
- 関連: `PeopleSupport.swift` / `LocalPhotoStore.swift`。
- 残課題: デフォルト MainActor 環境では「新しい top-level 関数・store メソッドが暗黙にメイン実行になる」ことをレビュー観点として持つ（同じ罠に再びはまりやすい）。

## @ModelActor が全処理をメインスレッドで実行（init したスレッドに束縛される罠）
- 症状: 操作中に最大 12〜14.5 秒のメインスレッドハング（設定が開かない等）。generate の純計算を Task.detached へ移しても解消せず、hang.begin センサーで「store 呼び出し（prune / fetch lite）の await 中」にメインが塞がると確定。
- 原因: SwiftData の `@ModelActor` は **init したスレッドで実行される**（DefaultSerialModelExecutor が生成時の ModelContext に束縛される既知の挙動）。`AutoAlbumStore` / `FaceStore` を MainActor（HomeStores.build → Engine.init 内）で生成していたため、@ModelActor なのに 85k 件の fetch/prune/upsert・顔の recordScan が**全部メインスレッド**で走っていた。actor だから勝手にオフメインだと思い込みやすく、await 越しなので呼び出し側コードにも現れない。
- 対処: `Task.detached` 内で Store を生成して注入するファクトリ（`AutoAlbumEngine.makeWithOffMainStore` / `PeopleEngine.makeWithOffMainStore`）を用意し、Composition Root から使用。直 init はテスト用に残し警告コメントを付けた。
- 関連: パフォーマンス実機分析（diagnostics-3.log）。`AutoAlbumEngine.swift` / `PeopleEngine.swift` / `AutoAlbumAdapters.swift`。MainThreadWatchdog の hang.begin（D4）が特定の決め手。
- 残課題: 新しい @ModelActor を追加するときは必ずオフメイン生成にする（レビュー観点）。DropboxCacheStore は自前 actor のため対象外。

## 重い処理の実行方針を「電源接続＋一定時間アイドル」に統一（設計判断）
- 症状/文脈: 背景 QoS でも、人が使っている最中に重い処理（アルバム生成・CLIP 埋め込み・顔スキャン）が動くと CPU/ANE/メモリを奪い使用感が落ちる。起動直後は全処理が同時突入しメモリ 668MB → システムストールも実測。
- 対処: `BackgroundYield.heavyWorkAllowed / heavyShouldPause` に一元化：電源接続＋低電力 OFF＋最後のユーザー操作から 60 秒以上アイドル＋（CLIP/顔は）生成との相互排他。操作は `BackgroundActivityMonitor.noteUserInteraction`（画面遷移・スクラブ・閲覧・取得の発生点）で記録。起動直後は非アイドル扱い。初回生成と手動実行（今すぐ生成・再解析）は例外。
- 関連: `BackgroundYield.swift` / `BackgroundActivityMonitor.swift`。従来の電源ポリシー設定（backgroundAllowed）はバックアップ・場所スキャン・Dropbox 同期に引き続き適用。
- 残課題: スクリーンロック中の実行（BGProcessingTask）は未実装（フォアグラウンドのアイドルのみ）。しきい値 60 秒は実機の体感で調整。

## 「人が写っていない風景写真」に人物写真が混入（否定条件が二重に不発）
- 症状: AI アルバムの条件「人が写っていない風景写真」で、人が写っている写真が選ばれる。
- 原因: 2 つの独立した不発。(1) **除外語が採点で未使用**＝LLM は contentExclude（["people"]）を正しく出していたが、`searchWithPool` は include しか読まず、QueryEvaluator も content 系を「ソフト＝採点側」として無視 → 除外の意図が誰にも適用されず捨てられていた。(2) **CLIP は否定を理解しない**＝英訳全文（"Landscape photos without people"）を単一ベクトルに埋め込んでおり、文中の "people" がむしろ人物写真への類似を引き上げる（既知のモデル特性）。
- 対処: 否定を**対比**に変換する2段構え。(1) 対比採点＝除外があるとき肯定側は include 語だけを埋め込み、各除外語は "a photo of X" で個別に埋め込む。画像ごとに「除外類似 ≥ 肯定類似」または「除外類似 ≥ 0.22（excludeDropThreshold）」で落とす（フル評価・増分評価で同一規則）。(2) 顔実測の統合＝人系の除外語（hasPeopleExclusion）を含むアルバムでは、顔スキャン済み写真の faceCount>0 をハード除外（ScannedPhoto → PeopleEngine.scannedFaceCounts → AutoAlbumEngine.setFaceCountsProvider の seam・FaceStore は別コンテナのため Composition Root で結線）。未スキャン・クラウド写真は CLIP 対比が受け持つ。テスト 5 件（対比ドロップ・絶対しきい値・顔実測・肯定フレーズ規則・人系判定）で固定。
- 関連: `AIAlbumSearch.swift` / `AIAlbumService.swift` / `FaceStore.swift` / `PeopleEngine.swift` / `AutoAlbumAdapters.swift` / `AIAlbumExclusionTests.swift`。ADR-23（解釈の永続化）の合成採点への拡張。
- 残課題: excludeDropThreshold（0.22）は実機の分布で調整。後ろ姿など顔検出に掛からない人物は CLIP 対比頼み。将来は対比プロンプト辞書の拡充や上位候補の VLM 再検証も選択肢。

## フルネーム指定の AI アルバムに同姓の家族全員が混入（人物接地の部分照合が波及）
- 症状: AI アルバムの条件に「木村太郎」とフルネームを入れたのに、木村花子ら**同姓の家族全員**の写真がヒットする。
- 原因: `PersonNameGrounder.groundedNames` は姓名の部分指定（「太郎」→木村太郎）に対応するため、各カタログ名から「全体＋前方（姓）＋後方（名）」の照合片を作りクエリ原文と突き合わせる。フルネーム「木村太郎」を入力すると、木村**花子**の姓片「木村」がクエリに含まれるため花子も接地され、ハード条件 people が家族全員に広がっていた。
- 対処: 2 パス照合に変更。第 1 パスで**フルネーム完全一致**（長い名前優先）を拾い、一致箇所をクエリから消費（空白化）してから、第 2 パスで残りに対して部分照合する。「木村太郎と花子」のような複合指定は従来どおり両方に当たる。テスト 3 件（波及なし・複合・最長優先）で固定。
- 関連: `PersonNameGrounder.swift` / `PersonNameGrounderTests.swift`。ADR-35 の人物ライブ照合とは独立（接地＝解釈側の問題）。
- 残課題: **1 文字の名（例「健」）は部分照合の対象外**（照合片は長さ 2 以上・1 文字は「健康」「健やか」等の通常語に誤爆するため現仕様として維持）。フルネーム入力またはコンポーザーのサジェストチップ（フルネームを挿入）なら当たる。形態素境界を使った安全な 1 文字照合は将来課題。

## バックアップの 409 を無確認で「済み」扱い（同名別写真がバックアップ済みと誤記録される欠陥）
- 症状: （実害発生前にオフロード設計のレビューで発見）Dropbox が 409（同パスに既存ファイルあり）を返すと、中身を確認せずその写真を「バックアップ済み」として記録していた。IMG_0001.jpg のようなファイル名は別の写真と普通に衝突するため、**実際にはバックアップされていない写真が「済み」になり得た**。バッジ表示が誤る程度で済んでいたが、オフロード（削除）実装後なら**永久喪失**につながる欠陥。
- 原因: 409 を「同じファイルが既にある」と楽観的に解釈していた。Dropbox の 409 は「同じ**パス**に何かがある」しか意味しない。
- 対処: 409 時は `files/get_metadata` でリモートの content_hash を取得しローカル計算値と照合。一致＝済み（検証済みとして記録）、不一致＝**autorename で別名アップロード**。あわせて通常アップロードも応答の content_hash 照合を必須化（HTTP 200 でも不一致なら済みにしない）。`OffloadSafetyTests` / `DropboxBackupUploaderTests` で固定。
- 関連: ADR-40。`DropboxBackupUploader.swift` / `BackupRunner.swift` / `DropboxContentHash.swift`。
- 残課題: 既存の「済み」記録に 409 由来の誤記録が混ざっている可能性（オフロードは実行時にその場で hash 再検証するため実害はないが、監査パスで洗い出すのが望ましい）。

## 台帳クリア＋端末フォルダ移行で同一写真が二重アップロードされる
- 症状: シミュレータ検証で、バックアップを繰り返すと Dropbox 上にファイルが増え続け、同じ写真がルート直下（/mosaicphotos/img_xxx.heic）と端末フォルダ（/mosaicphotos/iphone-xxxxxx/img_xxx.heic）の両方に存在した（SwiftData 記録: 写真 40 枚に対し記録 60 件・20 枚が 2 パスに重複）。
- 原因: 2 つの操作の相互作用。(1) 409 誤記録（別事例）の修復として **Clear upload progress** を実行し、済み台帳（UserDefaults）が空になった。(2) 直後の ADR-41 で**アップロード先が端末フォルダに変わった**ため、ルート直下の既存ファイルとの 409 重複検知（同一パス前提）が働かず、台帳の空白を埋める再アップロードがすべて新規ファイルとして端末フォルダに入った。差分判定の出典が「消える可能性のある台帳」だけだったことが根本原因。
- 対処: 済み判定を「**UserDefaults 台帳 ∪ SwiftData 記録**」に変更（記録は実アップロード成功時にのみ追加される確かな出典で、Clear upload progress では消えない）。実行時に台帳へ差分を書き戻して自己修復する。バッジ・状況表示（backupStatus）のキャッシュも同じ統合出典に。あわせてフォールバックファイル名を「photo_<実行内インデックス>.jpg」（実行をまたいで別写真が同名になり 409 を誘発する設計バグ）から localIdentifier 由来の安定名に修正。
- 関連: ADR-40/41。`BackupRunner.swift` / `BackupEngine.swift`。事例「バックアップの 409 を無確認で済み扱い」の続き。
- 残課題: 既に二重になったファイルの掃除は手動（ルート直下の旧ファイルを Dropbox 上で削除してよい——記録・台帳は端末フォルダ側でも成立する）。将来の監査パスで「同一 localIdentifier の複数記録」を検出して案内するのが望ましい。

## 「Clear Upload Progress」が効かない＋バックアップ済み数が Dropbox 全消去後も減らない
- 症状: Dropbox のファイルを全削除し、Debug の「Clear Upload Progress」を押してからバックアップしても「10 枚アップロード・40 枚バックアップ済み」と表示。クリアボタンは見かけ上何も起こさない。
- 原因: 二重アップロード修正（別事例）で済み判定を「UserDefaults 台帳 ∪ SwiftData 記録」にしたため、台帳だけを消すクリアボタンでは記録（40 件）から数が即復元される。さらに Dropbox 側でファイルを消しても、端末の記録は残るため表示と実態が乖離する——「実態（Dropbox）を出典にした修復手段」が無いことが根本。
- 対処: (1) **Reconcile with Dropbox**（照合）を実装: `files/list_folder`（再帰・continue 対応）でバックアップフォルダ以下の実ファイル一覧（path→content_hash）を取得し、実在しない/hash が矛盾する記録を削除、台帳も「照合に合格した記録」へ置き換える（409 誤記録時代の記録なし済み ID もここで一掃）。(2) **Clear ALL Backup Records**（台帳＋記録の全消去）を Debug に追加——全消去しても Dropbox に実在する分は次回バックアップの 409→hash 照合で再アップロードなしに「済み」へ復帰する。
- 関連: ADR-40〜42。`DropboxBackupUploader.listFolder` / `BackupEngine.reconcileWithDropbox` / `clearAllBackupRecords` / `BackupDebugSection`。
- 残課題: 照合は手動（Debug）。夜間の自動監査（定期 reconcile）への昇格は運用を見て判断。

## AI アルバム編集シートの開閉がもたつく（ウォームアップとの CPU 競合）
- 症状: AI アルバムの編集画面を開いて閉じるだけで妙に時間がかかる（シートの開閉アニメーションがもたつく）。
- 原因: シート表示と**同時**に走るウォームアップ群との CPU 競合。(1) CLIP テキストタワーの初回ロード（Core ML コンパイル・数秒）を `userInitiated` の detached タスクで実行しており、性能コアを遷移アニメーションと奪い合っていた。(2) サジェスト用スナップショット再構築（85k lite フェッチ＋カタログ構築）も userInitiated。メインスレッドのブロックではなく**優先度の高い並行 CPU 負荷**が原因（dismiss 自体は即時設計だった）。
- 対処: (a) コンポーザーの `.task` を **350ms 遅延**させ、表示アニメーション完了後にウォームアップを開始。(b) `TextEmbedder.prewarm()`（既定 no-op）を新設し、テキストタワーの前倒しロードを **utility 優先度**で実行（実クエリの embed は userInitiated のまま）。(c) カタログ構築も utility に。(d) あわせて増分再評価（refreshIncremental）の採点ループ（hardFilter＋decode＋vDSP コサイン×新規枚数）が **MainActor で実行**されていたのをオフメイン（detached・utility）へ——フォアグラウンドの埋め込み進行中に閲覧操作とメインを奪い合っていた。
- 関連: `AIAlbumComposerView` / `AutoAlbumEngine+Recognition.prepareAIComposer` / `MobileCLIPTextEmbedder.prewarm` / `AIAlbumService.refreshIncremental`。ADR-43（体感チューニング）の続き。
- 残課題: 開閉の所要は実機で要確認（PerfTrace `home.present` で計測可能）。JSONFileStore（解釈の保存）はメイン実行のまま（書き込みは KB 級で許容）。

## アルバム系ビューのオープンが遅い（メンバー ID フェッチのライブラリ走査）
- 症状: AI アルバム（＋ピープル/場所/端末アルバム）を開くと表示までワンテンポ待たされる。
- 原因: 開くたびに `PHAsset.fetchAssets(withLocalIdentifiers:)` を実行しており、メンバーが数千件あるとライブラリ走査で数百 ms 級かかる（オフメインだが time-to-first-content を直接遅らせる）。`local.loadAssets` の計測マークで確認可能。
- 対処: **PHAsset 全ライブラリ索引（`LocalAssetIndex`）**を起動後の段階起動（3 秒遅延・utility）で一度だけ構築し、アルバムオープンを **O(メンバー数) の辞書引き**（`LocalPhotoStore(preloadedAssets:)` 新設）に変更。索引未構築時は従来フェッチにフォールバック、索引構築後に追加された写真は不足分だけ小さく追いフェッチ（取りこぼしなし）。AI アルバム・ピープル・場所・端末アルバムの 4 ビューすべてに適用。
- 関連: `MosaicPhotos/Home/LocalAssetIndex.swift` / `LocalPhotoCore.LocalPhotoStore（preloaded init）` / 各アルバムビュー。ADR-43 の続き。
- 残課題: 索引は起動時スナップショット（追いフェッチで補正）。PHPhotoLibraryChangeObserver での自動更新は必要になったら。索引の常駐（数万 PHAsset 参照＋ID 文字列 ≈ 10MB 級）は LocalPhotoStore(.all) と同規模で許容。

## 夜間のオンデバイス解析が進まない（Wi-Fi 一律ゲート＋generate 再実行 jetsam＋二重起動）
- 症状: 実機を数晩充電しても People が埋まらず（ピープル 0）、顔スキャン・CLIP 埋め込みがほとんど進まない。診断ログ（diagnostics-11）で確認: (1) 顔スキャンの `already` が一晩で 4,280→5,640 とごく僅かしか増えない、(2) `generate`/`pathAlbum.full` が一晩で **24 回**走り footprint が **833〜884MB** まで跳ね、その直後に `footprint=2MB` の再起動が頻発（＝jetsam kill 濃厚）、(3) 起動毎に `faces: start` / `tags: start` が **2 回**、(4) 終盤に `[Tagger] embed: skipped — already running`。
- 原因: 複合。
  1. **Wi-Fi 一律ゲート**: [[ADR-25]] のゲート（`HeavyWorkTiming.allows`）が全作業に回線条件を課していたため、通信不要な**端末内写真の顔スキャン/埋め込み/タグまで** Wi-Fi 未接続/未検出（BG 起動直後は `NWPathMonitor` 初回コールバック前＝`isOnWiFi=false`）で停止。
  2. **generate の再実行ループ**: クラウド署名 `lastCloudSignature` がプロセス変数で**起動毎に 0 リセット**＋署名が `String.hashValue`（プロセス毎に seed 変動＝**起動を跨いで不安定**）だったため、jetsam 再起動のたびに「クラウドが変わった」と誤判定 →86k 件の重い generate（~800MB）を再実行 → また jetsam、の悪循環。
  3. **二重起動**: BG 起動プロセスで `HeavyWorkScheduler.runHeavyWork` が独自に `HomeStores.build()` する一方、UI シーンの `RootView` も別に build し、**PeopleEngine/AutoAlbumEngine が二重化**→顔/タグが 2 本走る。
  4. **BG 窓を generate が食う**: `runHeavyWork` が generate を**先に** await（~26s）してから顔/埋め込みを起動するため、数秒〜数分で expire する BG 窓では顔/埋め込みが開始すらしない。
  5. People が 0 の直接契機は Developer Options の「Reset people + corrections」手動実行（14:02）だが、上記で再スキャンが追いつかず 0 のまま回復不能だった。
- 対処（ADR-69＋本項）:
  - **ローカル/クラウドのゲート分離**（[[ADR-69]]）: `heavyShouldPause()` を回線不要の `heavyWorkAllowedLocal` に。クラウド分は `FaceTagger`（ローカル先・クラウド後回し・回線NGは除外）／`PhotoTagger`（既存 networkAllowed）／Vision タグ（回線NGはローカルのみ）で個別ゲート。
  - **署名の永続化＋決定的化**: `lastCloudSignature` を UserDefaults 永続にし、署名を **FNV-1a（起動を跨いで安定）**へ。jetsam 再起動での無駄な generate を根絶。
  - **単一 HomeStores**: `HomeStores.shared()`（in-flight 集約）で RootView と BGTask が同一インスタンスを共有＝二重化解消。
  - **BG 窓の順序**: `runHeavyWork` で**顔/埋め込みを先に**起こし、generate は空きメモリが十分（>900MB・700 から引き上げ）な時だけ後回しで実行。
  - **二重起動抑止**: `scheduleBackgroundFill` は `isTagging` を**同期的に**立ててから Task を起こす。
- 関連: `BackgroundYield`/`HeavyWorkTiming`(requiresNetwork)・`FaceTagger.scan`・`PeopleEngine.startScan`・`AutoAlbumEngine+Recognition`(scheduleBackgroundFill)・`AutoAlbumEngine`(signature/lastCloudSignature)・`RootView`(HomeStores.shared)・`HeavyWorkScheduler.runHeavyWork`・`HeavyWorkTimingTests`。[[ADR-25]]/[[ADR-69]]。
- 残課題: generate 自体のピーク（86k 件をメモリ展開＝~800MB）は据え置き（頻度を断って jetsam を回避した）。将来はページング化で峰を下げる余地。BG 窓が数秒で expire するのは OS 裁量で不可避＝1 窓あたりの生産性を上げる方針で対処。クラウド顔スキャン（68k 枚）はローカル完了後・Wi-Fi＋余裕時に少しずつ。

## オンデバイス AI の常駐メモリと UI 負荷の作り込み（モデル同時ロード・メインアクタの大規模処理）
- 症状: 夜間バッチが重く（jetsam 再起動が頻発）、Dropbox 同期中に UI がもたつく。診断で (1) facenet+CLIP2塔+VLM(877MB) が**同時常駐**し得る、(2) 顔モデルが**起動時にメインで eager ロード**、(3) 同期中に**メインアクタで 67k 件級の処理が 0.4 秒ごと**（items 全比較・merge 再ソート・map）と判明。
- 原因: モデルは遅延ロードだが**横断のロード制御・解放が無く**常駐が単調増加。UI 側は重い集約処理がメインアクタに残っていた（Observation の変化ごとに再構築・didSet の map・逐次 grouping 再構築）。
- 対処: 設計判断として [[ADR-70]]（モデル常駐制御: 遅延化 1-a／直列ロード 1-c／フェーズ相互排他 1-b／使用後・圧迫時解放 1-d）・[[ADR-71]]（UI の大規模処理を off-main/間引き: MergedStore デバウンス 2-a／Dropbox 比較の署名化 2-b／map・sort の off-main 2-c/2-d／PlaceGrouping 間引き 2-e）・[[ADR-72]]（generate 省メモリ 3-a／バックアップと AI の非同時実行 3-b）を実施。
- 関連: ADR-70/71/72 の「関連」を参照。app iOS ビルド緑・fast/ios テスト緑。
- 残課題: generate 自体の 86k メモリ展開はチャンク化の余地を残す（今回は返り値の削減＋頻度/常駐の抑制で jetsam 回避）。モデル推論の同時実行を semaphore で厳密に絞るのは将来の選択肢（現状はフェーズ相互排他＋ロード直列化で実質担保）。

## シミュレータで顔スキャンが走らない（ADR-25 フォアグラウンド停止で simulator の入口が消えた）
- 症状: シミュレータでピープルの数が増えない。「Run BG routine now」を押しても増えない。
- 原因: `FaceTagger.scan` はシミュレータでは既定でスキップ（cpuOnly で重いため）、`allowSimulator: true` のときだけ走る。foreground の `.task` は「Face scan in Simulator」トグルで allowSimulator を渡すが、[[ADR-25]] のフォアグラウンド完全停止で `heavyShouldPause`（アプリ操作中）に阻まれて実際には走らない。一方 `HeavyWorkScheduler.runHeavyWork`（＝「Run BG routine now」）は `startScan(...)` を **allowSimulator 無し（既定 false）** で呼んでいたため、シミュレータでは常にスキップ。結果、simulator に顔スキャンの入口が 1 つも残っていなかった（顔認識ロジック自体は正常）。
- 対処: `runHeavyWork` で `allowSimulator = BackgroundYield.debugForceHeavyWork || faceScanOnSimulator` を渡す。「Run BG routine now」は `debugForceHeavyWork=true` にするので、**トグル無しでもその場で顔スキャンが走る**（同時に heavyShouldPause も開くので 180s 窓の間は一時停止しない）。実機は `#if targetEnvironment(simulator)` ガード外なので不変。
- 関連: `HeavyWorkScheduler.runHeavyWork`（allowSim 追加）・`FaceTagger.scan`（simulator ガード）・`PeopleEngine.startScan`。[[ADR-25]]。
- 残課題: foreground の「Face scan in Simulator」トグル単体では（app active ゲートで）走らない。simulator 検証は「Run BG routine now」または「Force heavy work gates open」＋トグルで行う（実機は夜間 BGTask が本番経路）。

## 顔スキャンの高速化検討（スクショ除外＋所要内訳の計測・検出解像度は計測不能で保留）
- 症状/背景: 実機ログ（diagnostics-11）で顔スキャンが **約1.0s/枚**（64枚バッチ≈66s）、ローカル未処理 ~12,000枚＝純計算 3.3 時間で全体の最大ボトルネック。効率化を検討した。
- 分析（ログ実測・MARK タイムスタンプ差）: generate の 10〜28 分は **BG サスペンド由来で実 CPU ではない**（実 CPU は 20〜45s/回）。cloudPhotos<1s・launch→albums 3〜9s は許容。支配項は per-photo の ML 推論（顔・CLIP）。
- 対処:
  - **(a) スクリーンショットを顔スキャン候補から除外**: `localImageRefKeys` の fetch predicate に `(mediaSubtypes & photoScreenshot)==0` を追加。顔がまず写らないのに 1 枚 ~1s かかり backlog を膨らませていた。この候補パスは**顔スキャン専用**（CLIP 埋め込み/タグは別経路）なので検索/タグに影響しない。ライブラリの 1〜3 割削減見込み。
  - **所要内訳の計測を追加**: `faces.detect` ログに `load=…ms infer=…ms` を出す。ANE 実機で「1 枚 ~1s」のうちロードと推論のどちらが支配的かを次回ログで可視化する（判断材料）。
- 保留（理由つき）:
  - **(b) 検出解像度の 2 段化（1024→640 検出）**: 効果はあり得るが**計測不能**。リスクは「高解像度の集合写真の小さい顔の検出再現率」で、それを含むデータが無い（`face-eval/own/images` は空、LFW は 250px 中央顔、FG-NET は単一顔＝いずれも検出解像度を stress しない）。ADR-51 はユーザー実写真で 1024px を選定済み（プライバシーで削除）。**盲目的に下げると ADR-51 の小顔再現率を退行させ得る**ため、上記 load/infer 計測 →（Vision 支配なら）代表的な集合写真を用意して再計測、の順で判断する。
  - **(c) 画像プリフェッチ**: ロード支配なら有効だが、1024px CGImage(~4MB/枚) を先読み保持すると**直近の jetsam 対策と相反する**。load/infer 計測でロードが有意な割合と分かってから、メモリを抱えない形（1〜2枚のみのパイプライン等）で実装する。
- 関連: `PeopleSupport.localImageRefKeys`・`FacePerceptionAdapter.detectFaces`(load/infer 計測)。ADR-51（顔処理解像度）・[[ADR-25]]。
- 残課題: 次回実機ログで load/infer 内訳を確認 →(c)/(b) の可否を数値で判断。

## 実機で顔スキャンが動かない（People=0）＝真因は Vision×CLIP の ANE 同時実行デッドロック
- 症状: 実機で「夜間ルーチンを今すぐ実行」しても顔スキャンが 1 枚も進まず People=0 のまま。埋め込みは動くことがある。
- 真因: **顔検出（Vision `VNImageRequestHandler.perform`＝ANE）と CLIP 埋め込み／モデルロード（Core ML＝ANE）を同時に走らせると Neural Engine がデッドロック**し、Vision の perform が永久に返らない（detectFaces の逐次マークで「image 768x1024 ロード完了 → vision start の直後に停止」を確認）。以前顔スキャンが動いていたのは CLIP 埋め込みが Wi-Fi ゲートで止まっていて顔検出が ANE を独占できていたためで、ADR-69 で埋め込みが常時走るようになって表面化した。
- 対処: `PerceptionCore.MLInferenceGate`（actor の公平 FIFO ゲート・`run{ }`）を新設し、**ANE 系の重い処理を 1 つずつに直列化**する（顔検出＝`FaceTagger`、CLIP 埋め込み＝`PhotoTagger`、Vision タグ＝`TagTagger`、VLM キャプション、表示ラベラ prewarm）。単体では固まらないので、同時実行させなければデッドロックしない。ロード時に数十秒の順番待ちは出るが夜間トリクルなので許容。
- 追跡中に併せて見つかり修正した実バグ（本件と独立）:
  - `PHAssetImageLoader.image(for:)` の `PHImageManager` 継続が、**劣化版を無視して確定版だけで resume** していたため、`allowsNetwork:false`（背景解析）× iCloud 写真で確定版が来ず**永久ハング**。→ 劣化版で確定＋20秒タイムアウトを追加。
  - `CoreMLModelLoader.serializedLoad`（全モデルロードを 1 本の NSLock で直列化）が、1 つのロードの詰まりで**全モデルロードを永久ブロック**。→ 撤去（並列ロードに戻す）。
  - 生成フラグ滞留の安全弁（`BackgroundActivityMonitor.isGeneratingAlbums` の時間失効）＋デバッグ全開時の相互排他バイパス。
- 関連: `PerceptionCore/MLInferenceGate.swift`（新規）・`FaceTagger`/`PhotoTagger`/`TagTagger`/`AutoAlbumEngine+Recognition`・`PHAssetImageLoader`・`CoreMLModelSupport`・`BackgroundActivityMonitor`/`BackgroundYield`。[[ADR-69]]。
- 教訓: **ANE は単一資源**。Vision と Core ML を別スレッドから同時に叩くとデッドロックし得る。オンデバイスで複数の ANE 系推論を並行させず直列化する。`withCheckedContinuation` × コールバックは「特定条件でしか resume しない」実装だと、その条件が来ないケースで永久ハングするので必ずタイムアウト等の必ず resume する経路を用意する。

## drift フル再評価の並走と接地の空振り（diagnostics-50・ADR-110 の追い込み）
- 症状: (a) drift フル再評価が 10 秒間に 2 本並走し、make の採点が 79.6 秒
  （通常 0.4〜1.6 秒）に劣化。(b)「ballet dancer」が語彙の「ballet_dancer」と完全一致扱いに
  ならず、接地が「重心コールド」で deferred された。(c) 起動後最初の AI アルバム操作で
  9.4/10.2 秒のメイン飢餓（CLIP テキスト塔ロード 5.0 秒＋FM 初期化の CPU ストーム）。
- 原因: (a) refresh/finalize に in-flight ガードが無く、定期ティックと BG ルーチンが同時発火。
  (b) Vision 識別子は下線形・レキシコンは空白形で、exact 判定が区切りを正規化していなかった。
  (c) Core ML/ANE のモデルロードはシステム側スレッドで走り、呼び出し優先度では抑えられない。
- 対処: (a) `isEvaluating` ガード（refresh/finalizePending 共通・スキップをログ）。
  (b) exact 判定の区切り正規化（展開結果は語彙側の原形＝タグ照合に正しい形）。
  (c) プロセスあたり 1 回・十数秒の事象なので受容（発生時刻は作成操作直後に限定される。
  MetricKit の採取が届けばスタックで確定できる）。
- 実測の収穫: 重心構築は **118 秒**で完走（scanned 53,019）。過去の「約 30 分」は
  プロセス中断を跨いだ壁時計の誤読だった。夜間窓 1 回で余裕で収まる。
- 関連: diagnostics-50 / `AIAlbumService.swift` / `VocabularyGrounding.swift`。ADR-110。

## レビュー周りの 2 つのスケール劣化（diagnostics-51・人物 900 級で顕在化）
- 症状: (a) レビュー回答のたびにメインが 2〜4 秒固まる（46 ハングの大半・以前は 0.6〜0.7 秒）。
  (b) レビューを開くと 13.8 秒固まる（`people.reviewItems 13933ms` と 1:1）。
- 原因: どちらも**データ成長によるスケール劣化**。(a) 回答ごとの人物一覧再発行
  （`faces: people=N` publish → SwiftUI 再描画）が、人物数 400→900 級で線形に悪化。
  (b) 分割監査の凝集/分離統計が**全ペア類似 O(n²·d)** で、847 顔クラスタ＝約 72 万ペア
  × 512 次元の CPU 飽和がメインを飢餓させた（占有ではなく飢餓＝diagnostics-48 と同じ機序）。
- 対処: (a) レビュー UI（1対1・まとめて確認）の表示中は `beginPeopleReloadHold` で再発行を
  **保留**し、閉じるときに 1 回だけ反映（カード進行は一覧に依存しない）。
  (b) 監査の統計計算を**決定的等間隔サンプル（上限 120 顔）**に頭打ちし、
  **分割の割り当てだけは全員**を最近傍重心で行う（分割操作の対象を欠かさない）。
  900 顔の合成クラスタで全員割り当て・高速性・小クラスタの挙動不変をテストで固定。
- 関連: `PeopleEngine.setNeedsPeopleReload` / `FaceClusterAudit.auditForSplit`
  （maxStatisticsSample）。ADR-95（再発行の債務）・ADR-69（監査）。
- 残課題: 一覧再発行そのもの（保留解除後の 1 回）は依然 2〜4 秒。人物数がさらに育ったら
  差分 publish か一覧の段階描画を検討。

## サムネ待機者の取り残しレース（機内モード監査で発見・可視セルが永久スピナー）
- 症状: 潜在バグ（機内モード時の「通信待ちで固まって見える箇所」総点検で発見）。可視セルの
  サムネ要求が稀に解決されず、セルが再利用されるまでスピナーのまま＝固まって見える。
- 原因: `DropboxThumbnailBatcher` はバッチ取得中のパスを `inFlight` に入れ、その間の新規要求は
  「待機者登録のみ（配送を待つ）」にする。しかしチャンク内の**配送（deliver）と inFlight 除去の
  間に suspension がある**（他エントリのデコード `Task.detached`・キャッシュ書き込み await）。
  この窓で同一パスの再要求が来ると、配送は済んでいるのに待機者だけが残り、以後誰も配送しない。
  オンラインでは成功画像がキャッシュされ再要求がキャッシュヒットするためほぼ踏まないが、
  **失敗（nil）はキャッシュされない**ため、オフライン・不安定回線では同一パスの再要求が頻発して
  顕在化しやすい。
- 対処: チャンク完了時に `inFlight` を外すと同時に、そのパスに残った待機者へメモリキャッシュの
  結果（成功分）または nil を掃き出す（配送済み待機者は除去済みで二重配送なし）。回帰テストは
  「失敗エントリ＋大きい成功エントリ」の混在バッチでデコード窓を広げ、窓中の再要求が解決される
  ことを固定（修正前はタイムアウトで失敗することも確認済み）。
- 関連: `DropboxThumbnailBatcher.fetchThumbnailChunk` / `DropboxThumbnailChunkFetcher.fetch`。
  なお同監査で他経路は安全と確認: URLSession は `waitsForConnectivity` 未設定＝機内モードは即失敗
  （-1009）、フル画像は 3 回試行→失敗表示＋再試行、同期エラーはキャッシュ表示を妨げず 30 秒間隔
  リトライ、All Photos は Dropbox エラーでもローカル表示、背景処理は `networkAllowed()` でスキップ。
- 教訓: actor の「取得中フラグ＋待機者」パターンは、**配送とフラグ解除が同一 actor ターンで
  atomic に見えても、間に await があれば別の要求が挟まる**。完了時に取り残しを掃き出す出口を
  必ず用意する（待機者の解決を配送側の「網羅性」に依存させない）。

## クラウド共有の「反映中」が終わらない（per-key クエリの全表走査）
- 症状: 共有セット作成後、ハブの「反映中…」が終わらない（実フィードバック）。
- 原因: サイドカー生成の顔シグナル取得 `FaceStore.faceSignals(forRefKeys:)` が
  **写真 1 枚ごとに predicate 検索**していた。`DetectedFace.refKey` は非インデックス
  （unique は faceID のみ）なので 1 キーごとに全表走査＝数千キー × 数万行で実質終わらない。
  TagStore の同種 API は `set.contains` の単一クエリ、BackupStore の backupRefs は
  「全件 1 回 fetch → メモリで絞る」を既に採っており、新設 API だけ手筋を外していた。
- 対処: 少数キー（≤50）は per-key、多数キーは全件 1 回 fetch → メモリで絞る方式に変更。
  あわせて (1) セットごとに一覧を更新して進捗（共有済み N/M）を見えるように、
  (2) バックアップ無効で「バックアップ待ち」が残る場合はハブに原因と対処
  （設定でバックアップを有効に・クラウド写真は不要）を明示する案内を追加。
- 関連: FaceStore+ShareExport / ShareSyncEngine / ShareHubView（ADR-112）。
- 教訓: refKey で引く新 API を足すときは**そのテーブルのインデックス有無を必ず確認**する。
  非インデックス列への per-key predicate は SwiftData では気付きにくい全表走査になる
  （既存の backupRefs / tags(forRefKeys:) が正しい手筋の見本）。

## クラウド共有のコピー暴走（タイムアウト×autorename×自己同期の三重奏・diagnostics-52）
- 症状: 実機で長時間の固まり（メイン最大 12.9 秒・約 1 時間の高負荷）。Dropbox の共有フォルダに
  "IMG (1).jpg" 形式の重複が約 1,300 件生成され、items が 69,382→70,710 に膨張。
- 原因（3 つの因子の掛け算）:
  1. copy_batch の完了ポーリングが 60 秒でタイムアウトし「失敗」記録。しかし**ジョブは
     サーバー側で走り続ける**（Dropbox の async job はクライアントの離脱と無関係）。
  2. 次の反映が失敗分を **autorename つきで再コピー**→前のジョブの成果と衝突せず
     "IMG (1).jpg" を量産。リトライのたびに倍々で増えた。
  3. 自分のコピーが 1 秒ごとに longpoll 変更を発火し、そのたび **69k 件の全件フェッチ
     （1.2 秒）** が走行（変更は表示除外パス配下なのに反映処理が動いていた）→ CPU 飽和で
     メイン飢餓。
- 対処:
  1. **autorename 全廃**。宛先名は計画（SharePlanning）が決定的に割り当て（同名は " 2"
     連番）、衝突は失敗エントリとして返す。
  2. **採用（adoption）**: 宛先が既に実在し中身が一致するならコピーせず記録だけ更新
     ＝タイムアウト後に完了したジョブの成果を回収し、リトライを冪等にする。
  3. ポーリング上限 60 秒→4 分。
  4. **重複の自動掃除**: "name (N).ext" 形式で記録に属さず元名が実在するものだけ削除
     （安全側の条件・純ロジック＋テスト）。既にできた約 1,300 件は次回反映で片付く。
  5. **自己同期の抑制**: 差分通知に変更パスを載せ、変更が**表示除外パス配下だけ**なら
     items 反映（全件フェッチ）をスキップ（onCacheUpdated(changedPathsLower:)）。
- 関連: SharePlanning / DropboxShareCopier / ShareSyncEngine / DropboxSyncEngine /
  DropboxPhotoStore（ADR-112）。テスト: SharePlanningTests（採用・別名割当・掃除条件）。
- 教訓: **リモートの非同期ジョブは「タイムアウト＝失敗」ではない**。走り続ける前提で、
  リトライは必ず冪等（実在確認→採用）に設計する。autorename のような「衝突を黙って
  回避する」機構はリトライと組み合わせると増殖装置になる。
- 追記（diagnostics-53・修正前ビルドでの再発ログから発見）: **掃除の側にも上限があった**。
  `delete_batch` の API 上限は 1,000 件だが、掃除は全件を 1 リクエストで送っていた。
  この端末では 1 時間 40 分で items が 70,822→71,735（**913 枚増**）まで育っており、
  重複がさらに増えれば掃除そのものが失敗して**片付かないまま残る**ところだった
  （500 件チャンクへ分割・テストで固定）。暴走の後始末を書くときは、**後始末が扱う件数は
  暴走の規模に比例する**ことを前提に上限を確認する。
  同ログでは `people.load.clusters` が通常 360〜540ms に対し暴走中だけ 4,162ms まで伸びており、
  人物一覧の遅さも**独立した問題ではなく CPU 飽和の巻き添え**だったことが裏づけられた。

## ドキュメントがコードから 4 世代遅れていた（サイト内自己矛盾・棚卸しの記録）
- 症状: リリース 1.15 前の棚卸しで、公開ドキュメント（マニュアル `docs/help/` 9 ページ＋設計資料
  `docs/architecture-note/` 37 ページ）に大量の古い記載が判明。とくに設計資料は
  **同じサイト内で自己矛盾**していた——`design-decisions/adr.html` は「VLM キャプションを廃止した」
  （ADR-108）と書いているのに、`features/on-device-ai.html` や `index.html` は同じ機能を
  **現役の 3 段目パイプライン**として説明していた（約 25 箇所）。
- 原因: 「正本は records/*.md、HTML は派生物」という運用（CLAUDE.md）は守られていたが、
  **派生の更新が ADR 4 件ぶんで止まっていた**。ADR を書けば記録は残るので日々の開発は困らず、
  HTML の陳腐化は誰も痛みを感じないまま蓄積する。加えて、機能追加（クラウド共有 ADR-112・
  ピープルグループ ADR-113）は**そもそも派生先が存在しない**ので、差分を見ても気付けない。
- 主な乖離（5 分類）:
  1. **廃止機能が現役として残存**: VLM キャプション（ADR-108）。
  2. **換装が未反映**: 顔モデル facenet → AuraFace-v1（ADR-70）。README・マニュアル・設計資料の
     すべてが旧モデル名と旧数値（45MB / TAR 48.1%）のまま。
  3. **UI 名称の変更が未追従**: 時間と場所→旅行、自動アルバム→アルバム自動処理、
     Cloud Albums→フォルダーアルバム、確認ボタンの統合。
  4. **仕様の作り替えが未反映**: 「5 段階タイミング」は ADR-80 で 4 軸へ解体済みなのに、
     マニュアル・設計資料・README の 3 箇所すべてに残っていた。
  5. **新機能の欠落**: クラウド共有・ピープルグループが全ドキュメントにゼロ記載。
- 対処: 調査を 2 系統（マニュアル / 設計資料）に分けて全ページを実コードと突き合わせ、
  一括修正。設計資料には新章 `features/cloud-sharing.html` を追加。あわせて**コード側の
  古い文言も 2 件発見・修正**した（AI 解析状況の「クラウド写真は顔スキャン対象外」＝実際は対象、
  ホームの取り残しコメント）——ドキュメント監査がコードのバグを見つける側に回った例。
- 教訓: 「正本 MD ＋ 派生 HTML」は**派生の更新契機を仕組みに埋め込まないと必ず腐る**。
  最低限、(1) 機能を廃止したら派生の全文検索で名前を掃除する、(2) モデル・数値を変えたら
  README を含む全ドキュメントを grep する、(3) 新機能は ADR と同時に派生の章を作るか
  「派生なし」と決めて記録する、のいずれかを開発の締めに入れる。

## 掃除だけが空回りする（コピー失敗下での後始末ループ・diagnostics-55）
- 症状: 前回の暴走（diagnostics-52）を修正したビルドでも収束せず、実機で固まる＋短時間に
  3 回の再起動。`applyDelta() — added=0, removed=4` が **112 回**流れ続けた。
- 原因: 反映の順序が「**掃除 → コピー**」だったため、コピーが失敗し続ける状況で
  **掃除だけが毎回成立**していた。ログの内訳が決定的:
  ```
  '<セット名>' items=6073 copy=2688 adopt=1009 present=4100 dupes=2226 → 2226 件削除
  '<セット名>' items=6073 copy=2688 adopt=0    present=3600 dupes=1710 → 1710 件削除
  ```
  copy=2688 が減らない（＝正規ファイルが作られない）のに present だけが削られ、
  「削除 → Dropbox 変更通知 → 反映 → また削除」の空回りになる。削除の通知が 4 件ずつ
  細切れで届くため、差分同期も止まらない。
  コピー失敗の直接原因は `copy_batch` の HTTP エラーだが、**ステータスコードをログに
  残していなかったため特定できなかった**（レート制限が濃厚）。
- 対処:
  1. **順序を「コピー → 掃除」へ反転**し、**コピーが 1 チャンクでも失敗した回は掃除しない**
     （正規ファイルを作れていない状態で消さない）。
  2. **1 回の反映の作業量に上限**（コピー/削除とも 500 件）。残りは次回に持ち越す
     ——計画は毎回実在照合するので取りこぼさない。一度に流すとレート制限を誘発し、
     失敗→再試行でさらに負荷が増える悪循環になる。
  3. **429 / 5xx のリトライ**（`Retry-After` 尊重・指数バックオフ）と、失敗時の
     **ステータスコード＋レスポンス本文のログ**を追加。
- 関連: `ShareSyncEngine.sync` / `DropboxShareCopier.sendWithRetry`（ADR-112）。
- 教訓: **後始末（掃除・削除）は、本処理の成功を前提条件にする。** 本処理が失敗している
  ときに後始末だけが進む設計は、状態を「作られていないのに消される」方向へ発散させる。
  加えて、外部 API のエラーは**必ずステータスと本文を残す**——残っていなければ、
  次の一手は推測になる。

## コードレビューで見つけた「まだ起きていない暴走」（クラウド共有・7 件）
- 経緯: 実機で 2 度の暴走（重複大量生成・掃除の空回り）を修正した後、**残存バグを探す目的**で
  レビューを実施。既知の症状ではなく「同じクラスの障害を起こし得る経路」を洗い出した。
  純ロジックは実際に切り出して実行し、出力で確認している。
- 見つかった主なもの（すべて修正済み・テストで固定）:
  1. **自分のコピー先を再利用できず必ず複製**: `usedDestinations` に自分自身の `sharedPath` も
     予約していたため、再コピーに回ると `" 2"` が付く。バックアップ照合
     （`reconcileWithDropbox`）で記録が消えると全アイテムが `waitingBackup` へ戻り、
     **セット丸ごと複製**される経路だった。しかも生まれた旧ファイルは `"(N)"` 形式でないので
     掃除の対象外＝永久に残る。→ 記録済み `sharedPath` があれば**それを再利用**する。
  2. **削除と反映が排他されていない**: セット削除・単枚解除の直後に、走行中の反映が続きの
     チャンクをコピーし、消したはずのフォルダが写真つきで復活する（記録が無いので二度と
     掃除されない＝共有解除したのに共有されたまま）。→ 相互排他＋反映側の中断点で確認。
  3. **in-flight ガードが await をまたぐ（TOCTOU）**: `@MainActor` でも await で実行が移るため、
     トークン取得を挟むと 2 本が同時にガードを通過する。→ フラグを最初の await より前に立てる。
  4. **走行中の要求が黙って捨てられる**: 反映は数分かかるので、その間の「共有」操作が
     次のトリガまで反映されない（ユーザーには「何も起きない」）。→ 要求をコアレッシングして
     1 回だけ再走。
  5. **採用したファイルを同じ回に削除**: 掃除の除外集合が「計画前の記録」だけで、その回の
     採用・コピー先を含んでいなかった。→ 「今回の計画が使う予定のパスは消さない」を不変条件に。
  6. **`copyFailed` の判定漏れ**: リクエスト全体の失敗しか見ておらず、**エントリ単位の失敗**や
     **予算での打ち切り**では掃除が走っていた（宣言した不変条件と実装の食い違い）。
  7. **外部入力の日付が無検証**: サイドカーの顔 `d`（epoch 秒）だけ検証が抜けており、巨大値が
     `Date` になると人物の時期分割で**ソートの strict weak ordering が壊れる**（Swift の
     `sort` は未定義動作）。→ 有限性＋現実的範囲でフィルタ。
- 教訓:
  - **「予約」と「自分の持ち物」を混同しない**。衝突回避のための予約表に自分自身を入れると、
    再試行のたびに新しい名前を作る＝増殖する。
  - **破壊的操作は本処理と排他し、かつ「今から使う資源」を保護対象に含める**。
    後始末の除外集合は「過去の記録」ではなく「これから使う予定」まで含める必要がある。
  - **`@MainActor` は排他ではない**。await をまたぐガードは TOCTOU になる。
  - NaN は JSON で表現できないため送信側では出ないが、**巨大値は届く**。外部入力の数値は
    「有限か」だけでなく「現実的な範囲か」まで見る。

## 共有セットのライフサイクル: 作り直し・解除・中身の変化（ユースケース検証）
- 経緯: 実機で「グループを解除して同じ人物で作り直したら、共有バッジが出なくなった」という
  報告を受け、**ライフサイクル全体**（作り直し・共有解除・元の内容変更）をコードで検証した。
- 判明した挙動と問題:
  1. **作り直しでバッジが消える**: グループを解除すると新しい UUID が振られるが、共有セットの
     `sourceKey` は旧 UUID のまま。ID 照合しかしていなかったので一致せず、名前一致の
     フォールバックも「`sourceKey` が nil の旧セット」しか対象にしていなかった。
     → **作成元が現存しないセット**も名前一致にフォールバックする。
  2. **もっと悪い: 再共有で写真が二重にコピーされる**（本命の障害）。作り直した後にもう一度
     「クラウド共有…」すると、フォルダ名の衝突回避が働いて「名前 2」という**別セット**ができ、
     同じ写真がもう一組 Dropbox にコピーされる（容量が倍・共有相手からはフォルダが 2 つ見える）。
     → 作成元キー、無ければ**表示名**で既存セットを探し、**再利用して内容を更新**する。
  3. **グループ/アルバム/人物を消しても共有セットは残る**（設計どおり・共有は独立した実体）。
     ただし作成元を失った「孤児セット」は自動更新できないので、詳細画面でその旨を明示し、
     削除は手動に委ねる。共有解除（セット削除・単枚解除）では**共有フォルダの実ファイルも
     削除**される（記録だけ消すと孤児ファイルが残るため）。
  4. **中身の変化には追従しない**（ADR-112 のスナップショット方式）。グループにメンバーを
     足しても、AI アルバムが再評価されても共有セットは変わらない。仕様だが UI の説明が無く、
     追従手段も無かった。→ セット詳細に「**今の内容に更新**」を追加（作成元の現在メンバーを
     解決する seam `ShareSourceResolver` をアプリ側が実装）。元から外れた写真は共有フォルダ
     からも削除する。
- 教訓: **「共有」はユーザーの心的モデルでは元のアルバム/人物と一体だが、実装では独立した
  実体**。この乖離が、ID の張り替え・重複セット・追従なしという 3 つの症状を生んだ。
  UUID のような内部 ID で外部の実体（共有フォルダ）を束ねるときは、**ID が変わる操作
  （作り直し）を必ずユースケースとして検証する**こと。

## テストがプロセス共有の UserDefaults を踏み合って落ちる

- 症状: クラウド共有のシナリオテストが、**単体（`--filter`）では通るのにパッケージ全体で
  実行すると 15〜18 件まとめて落ちる**。落ち方は「反映結果が空（1 枚もコピーされない）」で、
  失敗までの時間も異常に短い（2.2 秒かかるはずのテストが 0.15 秒で終わる）。
- 原因: `ShareSettingsKeys` が `UserDefaults.standard` を直読みしていた。共有の設定は
  **プロセスに 1 つ**なので、「ネットワークを触らせない」目的で `provideEnabled = false` を
  書く別スイートと、`true` を前提に反映を走らせるシナリオスイートが並列に走ると、
  後者の `syncNow()` が丸ごと即 return する。テストコードの競合であり製品の不具合ではないが、
  **原因が製品側に見える落ち方**をするのが厄介だった（「共有が動かない」ように見える）。
- 対処: `ShareSettingsKeys` の読み出しに `defaults: UserDefaults = .standard` 引数を足し、
  `ShareSyncEngine` にも同じ seam を通した（本番の呼び出しは無変更）。テストは
  `UserDefaults(suiteName:)` でテストごとに独立したスイートを渡す。
- 関連: フォルダ名の種類接頭辞（ADR-112 追記）を入れた際、テストが 2 本増えて実行タイミングが
  変わったことで**もともと潜んでいた競合が表面化**した。3 回連続実行で再発しないことを確認。
- 残課題: 他パッケージにも `UserDefaults.standard` 直読みのテストが無いか、必要になった時点で
  同じ seam を通す（今回は BackupKit のみ）。

## 共有フォルダのパスがいつまでも新レイアウトにならない

- 症状: 端末フォルダ（`<root>/<端末名-短ID>/…`）と種類接頭辞（`People-` 等）を入れたのに、
  実機/シミュレータの Dropbox 上のパスが**古いまま**。反映を何度走らせても変わらない。
- 原因: 2 つ重なっていた。
  1. 接頭辞もレイアウトも**作成時にしか適用されない**。既存セットは同じ対象を共有し直しても
     「既存セットの再利用」経路に入るため、フォルダ名も置き場所も更新されない。
  2. さらに悪いことに、計画（`SharePlanning`）は `item.sharedPath`（記録済みのコピー先）を
     そのまま再利用する。これは重複コピー防止のために正しいが、結果として
     **フォルダを作る/一覧する先だけが新レイアウトになり、写真は旧パスへ書かれ続ける**。
     新旧が混ざるだけで、放っておいても収束しない。
- 対処: 反映のたびにフォルダのレイアウトを検査し、旧レイアウトの候補パス（端末フォルダ
  有り/無し × 旧名/新名）を順に `files/move_v2` で移動する。サーバーサイド move なので
  写真の再転送は無い。成功したら `folderName` と全アイテムの `sharedPath` を張り替える。
  **失敗した回は記録を進めない**（記録だけ進めるとクラウド上の実体を見失い全件コピーし直し）。
- 関連: ADR-112 追記2〜3。テストは「旧ルート直下セットの移動」「改名失敗時は旧フォルダ継続」
  の 2 本を偽サーバーで検証（`ShareScenarioTests`）。
- 教訓: **「作成時に決まる値」を変えたら、既存データの移行経路をセットで作る**。移行が無いと
  新旧が混在し、しかも今回のように「片方だけ新しくなる」中途半端な状態が定常化する。

## Keychain が使えない環境で端末 ID が毎回変わる（CI が赤くなった）

- 症状: GitHub Actions の fast ジョブ（`scripts/test.sh fast`）が失敗。ローカルでは
  クリーンクローンでも全件通る。ログは権限の都合で読めなかったため、**環境差**を疑って
  Keychain を無効化した状態を再現したところ、同じ落ち方をした。
- 原因: `BackupDeviceIdentity.currentID()` が「Keychain を読む → 無ければ生成して書く」だけで、
  **書き込み失敗を握り潰していた**。CI・サンドボックスのように Keychain が使えない環境では
  毎回書き込みに失敗するので、**呼ぶたびに新しい ID** が返る。この ID はバックアップ／共有の
  **フォルダ名そのもの**なので、パスを組み立てるたびに別の端末フォルダになり、
  テストの期待パスが一致しなくなっていた（`device-139abd` / `device-f24076` / `device-8b171a`）。
- 影響: テストだけの問題ではない。実機でも Keychain 保存に失敗すれば、バックアップ・共有の
  ファイルが端末フォルダの数だけ散らばり、**どれが自分のフォルダか分からなくなる**。
- 対処: (1) プロセス内メモ化（同一プロセスでは必ず同じ値）、(2) Keychain が駄目なら
  UserDefaults へ退避し、次回はそこから読む（読めた値は Keychain へ書き戻す）。
  解決ロジックは保存先を引数化した純関数 `resolveID(...)` に切り出してテストした
  （短 ID は端末の識別子でありクレデンシャルではないので、UserDefaults 退避で問題ない）。
- 関連: 端末フォルダ分離（ADR-112 追記）。この分離を入れたコミットは CI を通る前に
  ローカルで積み上がっていたため、**push して初めて環境差が露見**した。
- 教訓: 「保存に失敗したら生成し直す」は、**識別子**に対しては壊れた戦略になる。
  永続化に失敗しても**同一プロセス内では一定**にすること。

## 共有の削除が「成功したことにされる」3 つの穴

- 症状（潜在・コードレビューで指摘）: どれも最終的に「**ローカル記録は消えたのに、共有
  フォルダ側にはファイルが残る**」へ収束する。残ったファイルはどのセットにも属さないため、
  以後の反映では自分の持ち物と認識できず、掃除の対象にもならない（永久の孤児）。
- 原因と対処:
  1. `delete_batch` はバッチが完了しても**エントリ単位で失敗**する（no_permission 等）。
     全体成否しか見ていなかったため、削除できていなくても `true` を返していた。
     → エントリを検査し、`not_found` だけを成功に数える（「消したい物が無い＝目的達成」）。
  2. 変更操作は反映の停止を 3 秒待って**無条件に先へ進んでいた**。コピーのポーリングは
     最長 4 分で、途中で中断判定もしない。→ 反映をキャンセル可能な Task で回して停止を待ち、
     止まらなければ変更操作自体を中止する。
  3. リモート削除の失敗を握り潰して記録だけ削除していた。→ 消せたときだけ記録を消す。
- **修正しても残る穴**（重要）: Dropbox には**非同期ジョブを取り消す API が無い**。
  こちらがポーリングをやめても、サーバー側のコピーは完走する。削除直後に完走すると
  フォルダが復活し、記録は既に無い。→ 削除したフォルダの**墓標**（パス＋削除時刻）を 15 分保持し、
  以後の反映で「在れば消し直す」。期限切れの墓標は捨てる。
- 検証: 偽サーバーに削除失敗の注入（`failDeletePaths`）と外部削除（`remove`）を足し、
  4 本のシナリオで検証。**各テストが修正前のコードで実際に落ちること**を確認済み
  （復活フォルダの掃除・削除失敗時の記録保持・単枚解除の記録保持）。
- 教訓: 「失敗を握り潰して先へ進む」は、**外部の状態と自分の台帳を対にして持つ処理**では
  常に台帳を壊す。加えて、外部システムに取り消し手段が無い操作は、キャンセルでは守れない——
  **後から辻褄を合わせる経路**（墓標）が要る。

## 「記録してから消す」が記録の成否を見ていなかった（オフロード）

- 症状（潜在・コードレビューで指摘）: オフロード（ADR-40）の不変条件は
  **「台帳に記録してから端末の写真を消す」**。しかし `recordLedger` は `Void` で成否を返せず、
  実装の `upsertOffloads` も `try? modelContext.save()` で保存失敗を握り潰していた。
  容量不足や SwiftData 障害でも削除に進むため、**クラウドにしか無い写真が台帳から漏れる**。
  漏れた写真はアルバム合成にも復元にも現れず、追跡できない。
- 対処: `upsertOffloads` / `recordOffloads` / `recordLedger` を Bool にし、**永続化できたときだけ**
  削除へ進む。失敗時はその回の分をロールバックし、スキップ理由として返す。
- 併せて（同レビュー・P2）: metadata v2 の `offloadedAt` マーカー書き込みに失敗すると、
  「次回実行で再試行」というコメントに反して**永久に再試行されなかった**。対象の写真は既に
  端末から消えていて `offloadCandidateAssets()`（PHAsset 走査）に現れないため。
  マーカーは**再インストール後に台帳を建て直す唯一の手掛かり**なので、欠けると復元できない。
  → `OffloadRecord.markerUploadedAt`（nil＝未送信）を持ち、台帳を出典に再送する
  （`retryPendingOffloadMarkers`：バックアップ完走時とオフロード実行前）。
  成否判定のため `uploadJSON` の結果を文字列から `(ok:detail:)` に型付けした。
- 教訓: 「A してから B」の不変条件は、**A の成功を確認して初めて成立する**。戻り値を持たない
  seam（`-> Void`）は、その確認をコードで表現できない時点で危うい。
  また「次回再試行される」と書くときは、**次回の入力にその対象が現れるか**を必ず確かめる。

## 場所インデックスの署名が座標を見ていない

- 症状（潜在・コードレビューで指摘）: `placeScanSignature` は座標を持つアイテムの**パスだけ**を
  XOR していた。同じ Dropbox パスの写真が差し替わったり、位置情報が後から修正されても
  署名が変わらず再スキャンが走らないため、**古い市区町村に表示され続ける**。
- 対処: パスに加えて緯度・経度（小数 5 桁＝約 1m に丸める）を混ぜる。丸めるのは、
  浮動小数の下位桁のゆらぎで毎回再スキャンしないため。並び順非依存（XOR）は維持。
- 教訓: 「変化を検出する署名」は、**表示を左右する値をすべて含める**。ID だけの署名は
  「集合の増減」しか見ておらず、**中身の変化**を必ず取りこぼす。

## アカウント切替でキャッシュを引き継いでしまう（Dropbox）

- 症状（潜在・コードレビューで指摘）: **別アカウントで接続すると、旧アカウントの写真一覧が
  新アカウントのものとして表示され得る**。切替の判定はメモリ上の `lastKnownAccountId` で行い、
  さらに `resetLoad()`（切断時）がそれを nil に戻していたため、
  (1) 切断 → 別アカウントで接続、(2) 再起動を挟む切替、のどちらも検出できなかった。
  加えて `resetLoad()` は進行中の `loadTask` を止めておらず、リセット後に**古い一覧が
  再代入**され得た（キャッシュ本体も消えないまま）。
- 対処: キャッシュの持ち主を**永続化**して照合する。生の accountId は保存せず、
  SHA256 の指紋（先頭 16 桁）だけを持つ（等値比較にしか使わないため）。
  判定は純関数 `cacheOwnerDecision(stored:current:)` に切り出した:
  未接続＝何もしない（**記録を消さない**——消すと次の接続が「初回」に見えて切替を取りこぼす）、
  記録なし＝採用、一致＝温存、不一致＝**キャッシュ全消去してから採用**。
  `resetLoad()` / `clearCache()` / 切替検出は `loadTask` を必ずキャンセルしてから状態を消す。
- 教訓: 「前回の値と比べて変化を検出する」仕組みは、**前回の値がどこに・いつまで残るか**まで
  設計しないと成立しない。プロセス内変数は再起動で消え、リセット処理で消され、
  肝心の場面でだけ黙って無効になる。

## 初回同期が中断すると未走査フォルダが永久に取得されない（Dropbox）

- 症状（潜在・コードレビューで指摘）: 初回スキャンの途中でアプリ終了・通信エラー・キャンセルが
  起きると、キャッシュに「一部の写真＋カーソル」が残る。起動時の分岐は
  「カーソルあり かつ アイテム数 > 0 → poll へ直行」だったため、**未走査フォルダの既存写真は
  以後 Dropbox 側で変更されない限り永久に取得されない**（差分にしか現れないため）。
- 原因: カーソルはスキャン中にも書かれる（ページごとに書かないと中断時に何も残らない）。
  つまり「カーソルがある」は「走査済み」を意味しない——**別の事実を同じ値で表していた**。
- 対処: `DropboxSyncState.initialSyncCompletedAt`（完走時のみ記録）を追加し、起動時の分岐は
  この印で行う。既存インストールは印が無いので**一度だけ**初回スキャンをやり直す
  （中断済みかどうかは事後に区別できないため、安全側に倒す）。
- 教訓: 「途中経過の保存」と「完了の記録」は**別の値**で持つ。片方から他方を推測すると、
  中断したときだけ誤る——しかも症状は「一部が出ない」なので気づきにくい。

## 追い越された再構築が新しい一覧を上書きする（統合ストア）

- 症状（潜在・コードレビューで指摘）: `MergedPhotoStore.rebuildItems` は
  `Task.detached` で merge+sort し、`Task.isCancelled` を確認してからメインで代入する。
  しかし**確認と代入の間**にキャンセルされる競合は防げないため、新しい再構築が先に反映された後、
  古いスナップショットが遅れて `items` を上書きし得る。
- 対処: 再構築に**世代番号**を採番し、代入側でも現在世代と一致するときだけ反映する。
- 教訓: `Task.isCancelled` は「やめてよい」の助言であって、**順序の保証ではない**。
  非同期の結果を単一の状態へ書き戻すときは、世代（またはトークン）で最新性を判定する。

## 切断したのにセッションが復活する（トークン更新の追い越し）

- 症状（潜在・コードレビューで指摘）: 期限切れトークンの更新中にユーザーが「切断」すると、
  `disconnect()` は進行中の `refreshTask` を止めないため、**後から完了した更新が Keychain へ
  新しい資格情報を書き戻し**、`credential` も再設定されてしまう。ユーザーの操作に反して
  接続状態が戻る。OAuth 完了・直接トークン投入にも同じ穴があった。
- 対処: **認証世代**（`authGeneration`）を持ち、切断・認証キャンセルで進める。ネットワーク往復の
  開始時に世代を控え、**Keychain へ保存する直前にもう一度照合**して、食い違えば結果を捨てる。
  `disconnect()` は `refreshTask` を cancel して手放す。
- 教訓: 非同期の往復は「開始時の前提」が終了時にも成り立つとは限らない。**保存の直前**に
  前提を確認する（開始時のガードだけでは、往復の間に起きた操作を追い越す）。

## クラウド分だけリセットしたのにクラスタの重心が古いまま（顔）

- 症状（潜在・コードレビューで指摘）: `resetCloudScans()`（ADR-90）はクラウドの `DetectedFace` と
  `ScannedPhoto` を消すが、`PersonCluster.sum/count` には**消した顔の寄与が残る**。
  インメモリの `clusteringCache` を捨てても、次のスキャンは残った `PersonCluster` 行から復元する
  ため、再スキャンしたクラウド顔がさらに加算されて**重心と件数が二重化**する。
  メンバーが居なくなったクラウド専用クラスタも幽霊として残る。
- 対処: 顔を消した直後に `rebuildClusters()` で**残った顔だけから組み直す**
  （命名・確認顔は種として保持されるので名前の持ち越しは不変）。併せて `rebuildClusters()` が
  「顔 0 件」で素通りしないようにした——クラスタ行だけが残ると同じ二重計上を招くため。
- 教訓: 集約値（合計・件数）を持つ行と、その素になる行は**必ず同時に更新する**。
  キャッシュ無効化は「読み直し」を保証するだけで、読み直す先が古ければ何も直らない。

## 採点していないのに「評価済み」にする（AI アルバムの増分再評価）

- 症状（潜在・コードレビューで指摘）: 増分再評価は `evaluatedEmbedCount` を進めてから
  クエリ埋め込みを取りに行っていた。モデルの一時的なロード失敗やキャンセルで埋め込みが
  取れないと、その回の写真は**採点されていないのに評価済み**として保存される。
  ドリフト検知（評価済み枚数と現在の埋め込み枚数の差）も差分ゼロと判断するため、
  **その写真は二度と評価されない**（AI アルバムに永久に入らない）。
- 対処: 件数は採点が成立した経路でだけ進める。埋め込みが取れなかった回は**何も保存せず**
  次回へ回す（ハード条件だけで完結する経路は、そこで評価済みに数える）。
- 教訓: 「進捗カウンタ」は**成果の後**に進める。先に進めると、失敗が「完了」として記録され、
  再試行の手掛かりが消える（同種の誤りをオフロードのマーカーでも踏んでいる）。

## グリッドの指紋が「件数＋両端」で、中間の入れ替えを取りこぼす

- 症状（潜在・コードレビューで指摘）: `PhotoCollectionView` は指紋が変わらない限り snapshot と
  `idToIndex` を作り直さない。指紋が「件数｜グルーピング｜先頭 ID｜末尾 ID」だったため、
  **件数と両端が同じまま中間だけ変わった**場合（1 枚消えて 1 枚増えた・並び替え）を取りこぼす。
  取りこぼすと `items` だけが差し替わり、dataSource と `idToIndex` は古いまま——
  **別の写真が表示され、タップしたときの ID も食い違う**。
- 対処: ID 列全体から指紋を作る（`gridIdentitySignature`・純関数として切り出しテスト対象化）。
  68k 件でも数 ms で、防いでいる snapshot 再構築（0.5〜1s）よりはるかに安い。
  `items.lazy.map(\.id)` で中間配列を作らない。
- 教訓: 「変化検出の指紋」に**表示を左右する要素を全部入れる**のは、場所インデックスの
  座標と同じ誤り（同レビュー群で 2 度目）。安く済ませた指紋は、安く済ませた分だけ嘘をつく。

## 無効化した画像が、遅れて着地した書き込みで復活する（Dropbox キャッシュ）

- 症状（潜在・コードレビューで指摘）: サムネイル／フル画像の保存は、エンコードとディスク I/O を
  actor の外（detached）で行う。そのため **取得 → 保存開始 → 無効化（Dropbox 側の更新・
  アカウント切替）→ 保存完了** の順序が起こり得て、古いバイト列と使用量記録が復活する。
  アカウント切替では前アカウントの画像が戻り得た。
- 対処: 保存要求に**書き込みトークン**（全体世代＋パス単位の無効化回数）を持たせ、
  書き込み前と記録前の両方で照合する。書いている最中に無効化された場合は書いたファイルを
  削除して記録しない（I/O は actor 外のままなので、一瞬だけ存在して必ず収束する）。
  無効化記録が肥大したら捨てて全体世代を進める（安全側＝進行中の保存を諦める）。
- 補足: 既存テストにはこの競合を避けるための `Task.sleep` が入っていた——**テストの都合**として
  扱われていたが、実際は製品側の競合だった。
- 教訓: 非同期に切り出した書き込みは、**着地時点でまだ有効か**を必ず問う。切り出した時点の
  前提は、着地時点の前提ではない（同レビュー群のトークン更新・セッション復活と同じ構図）。

## キャンセルが要求 ID の登録を追い越すと、取得が止まらない（PhotoKit）

- 症状（潜在・コードレビューで指摘）: `requestImage` が ID を返す前にキャンセルハンドラが走ると
  （AsyncStream の終了直後など）、ID は無効値のままで `cancelImageRequest` は何も取り消せない。
  その後で要求が登録されるため、**画面外になったサムネイル取得が最後まで走り続ける**。
  高速スクロールでは不要な要求が大量に残る。
- 対処: 要求 ID とキャンセル状態をロック付きの箱（`PHImageRequestBox`）で対に扱う。
  `register(_:)` は「既にキャンセル済みか」を返し、その場で取り消せるようにする。
  完了通知も `markFinished()` で 1 回だけ通す（degraded → final の二重 resume 防止）。
- 教訓: 「ハンドラ登録」と「ハンドラが参照する状態の初期化」が別の行にある限り、
  その間に割り込まれる。順序を仮定せず、**どちらが先でも成立する**形にする。

## 通信障害が「メタデータの消去」に化ける（バックアップ）

- 症状（潜在・コードレビューで指摘）: メタデータ v2 のシャード更新は
  「既存をダウンロード → マージ → 上書き」。`download()` が**ファイル未存在も通信障害も
  同じ nil** で返していたため、認証切れ・タイムアウト・5xx のときに「空のシャード」と読み、
  **その月の既存メタデータ（人物名・アルバム・位置情報）を新規分だけで上書き**していた。
  catalog.json も同じ経路だった。
- 対処: `downloadResult(path:token:)` を追加し `found / notFound / failure` を区別する
  （`notFound` は 409 の本文に `not_found` があるときだけ）。`failure` のシャードは
  **書かずに飛ばす**。オフロードのマーカー書き込みも同じ規則に揃えた。
- 併せて（同レビュー・P1）: メタデータの送信失敗は**再試行されないまま完了扱い**だった。
  写真の実体を上げた時点で ID が台帳と SwiftData に記録され、以後 pending に入らないため、
  同じ写真は二度と対象にならない＝欠落が永久化する。→ 失敗分を
  `PendingMetadataStore`（Application Support の JSON）へ残し、次回の実行で先に送り直す。
  カタログだけ失敗した場合も、書けたシャードを保留に残して次回作り直させる。
- 教訓: **「無い」と「読めない」を同じ値で表さない**（同レビュー群のカーソルと同型の誤り）。
  そして、失敗したときに**次の機会が来るか**を必ず確かめる——来ないなら、その場で
  再送キューに積むしかない（オフロードのマーカーと同じ構図・3 度目）。

## キャンセル直後の再実行で、旧タスクが新タスクのハンドルを消す（バックアップ）

- 症状（潜在・コードレビューで指摘）: `cancel()` は旧タスクの終了を待たずに `backupTask` を
  nil にして `phase` を `.cancelled` にするため、すぐ次の実行を始められる。その後で旧タスクが
  終わると、クロージャ末尾の `backupTask = nil` が**新しい実行のハンドルを消す**
  （以後キャンセル不能）。旧タスクからの `phase` 更新が新しい進捗を上書きすることもある。
- 対処: 実行世代（`runGeneration`）を採番し、`cancel()` と `start()` で進める。
  後始末は自分が現行世代のときだけ行う。委譲は `GenerationScopedRunnerDelegate` で包み、
  旧世代の `phase` / ログ更新を通さない。**ただし記録の保存（`runnerSaveRecord`）は世代に
  関わらず通す**——アップロード自体は完了しているので、捨てると実体はあるのに記録が無い
  （次回また上げてしまう）状態になる。
- 教訓: 「止めた」と「止まった」は別。ハンドルを nil にするのは*要求*であって*完了*ではない。

## 低品質顔の付け替えでクラスタが消える（顔）

- 症状（潜在・コードレビューで指摘）: 品質フロア未満の顔は「membership だけ」割り当て、
  重心（`sum`/`count`）には寄与しない（第2パス・ADR-66）。ところが付け替え（`reassignFace` /
  分離 / 同一写真の修復）は**すべての顔**について `removing` を呼び、ベクトルを減算し count を
  1 つ減らしていた。`count == 1` のクラスタでは「最後の 1 顔」と誤認して**クラスタごと削除**され、
  残った顔が存在しないクラスタ ID を指す。通常の「別の人物へ付け替える」操作だけで起きる。
- 対処: `DetectedFace.contributesToCentroid` を永続化し、**寄与した顔だけ** sum/count から引く。
  記録は `recordScan`（本割り当て＝true、第2パス＝false）と `rebuildClusters` の書き戻しで更新する。
  列が無い旧行は品質フロアで推定する（フロア未満＝寄与なし）。付け替え先へ入れるときも
  同じ規則で、フロア未満なら membership だけにする。
- 教訓: 「加算した条件」と「減算する条件」は**同じ述語**でなければならない。加算側だけに
  条件があると、減算は必ずどこかで帳尻を壊す。

## 人物 ID の再利用で、別人の写真を共有し得る

- 症状（潜在・コードレビューで指摘）: クラウド共有の作成元キーは `person-<clusterID>`。
  しかし `clusterID` は**永続 ID ではない**——顔を全消去して再スキャンすると 0 から振り直される。
  共有セットは別コンテナ（BackupKit）にあるため参照だけが残り、`person-3` が以前とは別人を
  指しても resolver は「現存する ID」として受理する。次の反映で**別人の写真を家族フォルダへ
  追加**し得た。
- 対処: 全消去のタイミング（手動リセット・パイプライン版上げの再スキャン）で
  `PeopleEngine.onPersonIdentitiesInvalidated` を発火し、アプリ（Composition Root）が
  `ShareSyncEngine.detachPersonSources()` を呼んで**人物由来の作成元キーだけ外す**。
  セットと共有済みの写真は残り、同じ名前で共有し直せば再び結び付く（グループは UUID なので対象外）。
- 検討したが採らなかった案: 人物へ永続 UUID を持たせる。より根本的だが、clusterID は
  クラスタリング・UI・束ね・共有の広範囲で使われており、影響が大きい。
  「番号が当てにならなくなった瞬間に参照を切る」方が小さく確実。
- 教訓: **他コンテナへ渡す識別子は、その寿命を渡す側が保証できるものに限る**。
  寿命の違う ID を跨がせるなら、無効化のイベントもセットで設計する。

## 解析結果の保存失敗でもサイドカーを取り込み済みにする

- 症状（潜在・コードレビューで指摘）: 共有サイドカーの取り込みは、写真の content_hash が
  全部見つかったか（`fullyMatched`）だけで rev を記録していた。各ストアは SwiftData の
  save エラーを `try?` で握り潰すため、**保存に失敗しても「取り込み済み」**になり、
  同じサイドカーは以後ダウンロードされない＝欠けた解析結果を再取得できない。
- 対処: `recordTags` / `upsertImportedEmbeddings` / `recordScans` が保存の成否を返し、
  `importSharedAnalysis` / `importFaceScans` が `saved` を伝播、**全部コミットできたときだけ**
  `markImported` する。失敗時は診断ログに残して次回再試行する。
- 判断: 壊れた顔埋め込み（base64 デコード失敗）で脱落する分は**再試行しても直らない**ため、
  取り込み済みの記録は妨げない（永久ループを避ける）。ブロックするのは**回復可能な失敗**だけ。
- 教訓: オフロードのマーカー・AI アルバムの評価済み件数・バックアップのメタデータに続く
  4 例目。**「完了の記録」は、完了を確認してから**。

## 待ち時間中にページを送ると、別の写真を共有・巻き戻す（フル写真ビュー）

- 症状（潜在・コードレビューで指摘）: フル写真ビューは取得・書き込みの待ち時間中も横ページ
  送りができる。開始時と完了時のページを突き合わせていなかったため、
  - **共有**: A で共有を押して B へ移動したあとに A の取得が終わると、B を見ているのに
    A の共有シートが開く＝**見ている写真と違う写真を外部へ送る**。
  - **お気に入り**: A のハートを押して B へ移動したあと A の書き込みが失敗すると、
    巻き戻し先が完了時の `currentID`（＝B）になり、**B のハートを A の旧値で上書き**する。
- 対処: 開始時に `pageID` を控え、共有は `currentID` と一致するときだけシートを出す。
  お気に入りは楽観更新も巻き戻しも `pageID` に固定する。判定は純関数 `PageBoundResult` に
  切り出してテスト対象にした。共有シートの `id` も写真 ID にし、利用記録も共有した写真へ付ける。
- 教訓: 非同期の結果は**開始した文脈**へ返す。完了時に「今の状態」を読むと、待っている間に
  起きた操作を無視して上書きしてしまう（同レビュー群のトークン更新・キャッシュ書き込みと同型）。

## 共有していたのが原画ではなく表示用の縮小画像

- 症状（潜在・コードレビューで指摘）: 共有に `store.fullImage(for:)` を使っていた。これは
  ビューア表示用 API で、ローカル・Dropbox とも約 2048px へ縮小した `UIImage` を返す
  （ズーム無しの表示に十分＝メモリ削減のため）。共有すると**解像度・EXIF・元のファイル名・
  元の形式**が失われる。
- 対処: `PhotoOriginalProviding.originalForSharing(_:)` を追加し、原バイト列＋元のファイル名を
  返す。ローカルは `PHAssetResource`（編集済みがあれば fullSizePhoto を優先・iCloud 取得許可）、
  Dropbox はフル画像キャッシュの**原バイト**（無ければダウンロード）。一時ファイルへ
  元の名前で書き出し、`UIActivityViewController` には URL を渡す。取得できない場合だけ
  従来どおり表示用画像へフォールバックする。
- 残課題: Live Photo の動画部分は含めていない（静止画のみ共有）。必要になったら
  `PHAssetResource` の `.pairedVideo` を併せて渡す。
- 教訓: 「表示のために劣化させた値」を**表示以外の出口**（共有・書き出し・アップロード）へ
  流用しない。用途ごとに取得 API を分ける。

## BGTask の完了を二重通知し、期限切れ後も解析が走り続ける

- 症状（潜在・コードレビューで指摘）: 3 つ重なっていた。
  1. 期限切れハンドラが `setTaskCompleted(success: false)` を呼んだ後、キャンセルされた本体も
     終了処理へ進んで**もう一度** `setTaskCompleted` を呼ぶ。BGTaskScheduler は二重呼び出しで
     例外を投げる。
  2. `runHeavyWork` は顔スキャン（`startScan`）と背景埋め込み/タグ（`restartBackgroundFill`）を
     **起動するだけ**で待たない（短い BG 窓を食い潰さないための設計）。よって `work.cancel()` では
     止まらず、**OS へ完了を通知した後も解析が走り続ける**。
  3. `runHeavyWork` は常に `BackgroundYield.isAppActive = false` を立てるが、前面から叩く
     デバッグ実行（`debugRunNow`）で元に戻していなかった。次の scenePhase 変化まで
     「非アクティブ扱い」が残り、**ユーザー操作中でも重い処理が走れる**状態になる。
- 対処: (1) 完了通知を `CompletionLatch`（MosaicSupport・純ロジック・テスト済み）で一度きりにする。
  (2) 停止経路に `stopBackgroundProcessing(cancelBackup:)` を用意し、期限切れ・デバッグ時間切れ・
  フォアグラウンド復帰で顔スキャンと背景処理を明示的に止める。**バックアップは期限切れ時のみ**
  キャンセルする——フォアグラウンド復帰でも止めると、ユーザーが自分で始めたバックアップを
  中断してしまう（区別できないため）。 (3) `runHeavyWork(restoreAppActive:)` を追加し、
  デバッグ実行だけ終了時に元の値へ戻す。
- 教訓: 「起動しただけのタスク」は**キャンセルの網に入らない**。窓を食い潰さないために
  待たない設計にしたなら、止める側も明示的に列挙するしかない。
  グローバルなフラグを一時的に変える処理は、**戻す責任**も同じ関数に持たせる。

## 一時的なオープン失敗で、台帳ごと消してしまう（自己修復コンテナ）

- 症状（潜在・コードレビューで指摘）: `makeResilientModelContainer` は `ModelContainer` の
  初期化に失敗すると**理由を見ずに** store / -wal / -shm を削除して作り直していた。
  この共通処理は BackupKit（バックアップ記録・オフロード台帳・未送信マーカー・共有状態）でも
  使われており、**ディスク容量不足やファイル保護（端末ロック中）のような一時的な失敗**でも
  台帳が消える。消えると二重アップロードや共有の齟齬になる。
- 対処: 失敗を分類する（`StoreRecovery`・純ロジック・テスト済み）。
  - 一時的（容量不足・書き込み不可・保護中・I/O 一時障害。`NSUnderlyingError` まで辿る）→
    **何も消さず**、その起動だけインメモリで動かす。次回の起動で元のファイルから開き直せる。
  - 破損・スキーマ不整合 → ポリシー次第。**再構築できるキャッシュ**（タグ・埋め込み・
    サムネのメタ）は従来どおり削除、**台帳**（BackupKit）は削除せず `*.corrupt` へ**退避**して
    作り直す（3 世代まで保持）。退避にも失敗したら消さずインメモリで起動する。
- 教訓: 「自己修復」は**壊れたときの手当て**であって、**繋がらないときの手当て**ではない。
  復旧処理を書くときは「何が失敗したのか」を先に分類する。区別しない復旧は、
  一番データが必要な場面（容量不足・端末ロック中）で一番の破壊者になる。

## ディスク書き込みの失敗を成功として記録し、使用量が壊れる

- 症状（潜在・コードレビューで指摘）: `DiskImageStore.write` はディレクトリ作成と
  atomic write のエラーを両方 `try?` で捨て、戻り値も無かった。呼び出し側
  （`ThumbnailCache` / `DropboxCacheStore`）は書けた前提で `diskUsage` や使用量レコードへ
  加算するため、**実ファイルが無いのに使用量だけ増える**。その架空の値を基準に LRU が
  正常なキャッシュを削り続け、容量不足の状況から回復しない。
- 対処: `write` を `Bool` にし、**成功したときだけ**使用量を更新する。Dropbox 側は
  失敗をログに残して使用量記録もスキップする。
- 教訓: 「書いた」と「書けた」を同一視しない（同レビュー群の台帳保存・メタデータ送信と同型）。

## 原本共有が全データをメモリへ載せ、キャンセルも効かない

- 症状（潜在・コードレビューで指摘）: 共有用の原本取得が `PHAssetResource` の全チャンクを
  `Data` へ連結し、そのあと一時ファイルへ書き出していた。RAW / ProRAW / 高解像度では
  **原本サイズ以上のメモリピーク**になる（連結分＋書き出し分）。さらに要求 ID を保持して
  いないため、ページ移動やビュー破棄のあとも iCloud 取得とバッファ確保が最後まで続く。
- 対処: 届いたチャンクを `FileHandle` でその場で書き（メモリに溜めない）、`SharedOriginal` は
  **書き出し済みの URL** を持つ形にした。要求 ID は `PHImageRequestBox`（登録とキャンセルを
  ロックで対に扱う既存の箱）で管理し、タスクキャンセル時に `cancelDataRequest` を呼ぶ。
  一時ファイルは次の共有の準備時に片付ける（原本は大きいので溜めない）。
- 教訓: 大きなバイナリは**受け取りながら流す**。全部揃えてから次の処理へ渡す形は、
  サイズが上限のない入力（原本・動画）では必ずメモリで詰まる。

## 削除したはずの AI アルバムが、評価完了後に復活する

- 症状（潜在・コードレビューで指摘）: 本番化（`finalizeNow` / `finalizePending`）とフル再評価は、
  開始時にアルバムを取得したあと FM 解釈・検索・LLM 審査で**数秒〜数十秒 await する**。
  その間にユーザーが削除しても、最後の `store.upsert(albumInfo:)` が同じ ID を再作成する。
  編集（検索文の変更）と競合した場合は、**古い条件の結果が新しい内容を上書き**する。
- 対処: アルバムごとの世代（作成/再設定/削除で進む）を持ち、保存の直前に
  「まだ存在し、条件と世代が開始時のまま」を確認してから書き戻す。解釈の保存も同じ関門を通す。
- 教訓: 非同期の結果を**共有の永続状態へ書き戻す**処理は、開始時の前提が保存時にも
  成り立つか確認する（同レビュー群のトークン更新・キャッシュ書き込み・共有シートと同型で 4 例目）。

## 相対日付のアルバムが、時間の経過では更新されない

- 症状（潜在・コードレビューで指摘）: フル再評価の起動条件が「解釈バージョンが古い」か
  「埋め込み枚数の差 > 500」だけだったため、「直近 30 日」のような**範囲が日々動く**条件でも、
  写真が増えなければ再評価されない。さらに増分評価は既存メンバーを維持するので、
  期間外になった写真が**残り続ける**。
- 対処: `SavedInterpretation.lastEvaluatedAt`（フル評価時のみ更新）を持ち、
  時間依存の日付条件があり日付境界を越えていたらフル再評価する（`RelativeDateStaleness`・純ロジック）。
- 教訓: 「入力が変わったら再計算」は、**時刻そのものが入力**の条件では成立しない。
  時間を入力に持つ評価は、時間の経過も変化として扱う。

## 増分評価で見送った写真が、どこにも残らない

- 症状（潜在・コードレビューで指摘）: 待機列（`pendingNewEmbeds`）を await の前に空にしていたが、
  `refreshIncremental` はクエリ埋め込みを取得できないアルバムを `continue` するだけ。
  その refKey は評価済みにもならず待機列にも戻らないため、追加枚数がドリフト閾値を超えるまで
  アルバムへ入らないままになる。
- 対処: `refreshIncremental` が延期した refKey を返し、エンジンが待機列へ戻す。
  再処理での二重加算を防ぐため、評価済み件数は現実の埋め込み総数を上限に頭打ちする
  （既存値は下回らせない＝カウントを減らして無駄なフル評価を誘発しない）。
- 教訓: 「取り出してから処理する」待機列は、**処理できなかった分を戻す経路**まで含めて設計する
  （オフロードのマーカー・バックアップのメタデータに続く 3 例目）。

## 写真ライブラリの変更に追従していない 3 箇所（一覧・索引・端末アルバム）

- 症状（潜在・コードレビューで指摘）: いずれも「起動時に一度読む」「TTL で判断する」だけで、
  `PHPhotoLibraryChangeObserver` を張っていなかった。
  1. **一覧**（`LocalPhotoStore`）: 表示中の撮影・取り込み・削除・限定アクセスの範囲変更が
     `items` に反映されない。`MergedPhotoStore` の監視も発火しない。
  2. **索引**（`LocalAssetIndex`）: 一度作った `localIdentifier → PHAsset` の辞書を無効化しないため、
     **削除済みの写真を返し続ける**。人物・場所・AI アルバムのメンバー画面に空セルが残る。
     追いフェッチした新規アセットを辞書へ入れていないので、開くたびに同じフェッチを繰り返してもいた。
  3. **端末アルバム**（`LocalAlbumScanner`）: 24 時間キャッシュを無条件に採用するため、
     アルバムへの追加/削除・アルバム名変更・アルバムの作成/削除が最大 1 日反映されない。
- 対処: 共通の `PhotoLibraryChangeObserver`（LocalPhotoCore）を用意し、
  1. 一覧はデバウンス（400ms）して再読み込み。**固定リストのストア**（人物・場所などの
     メンバー画面＝`preloaded`）は削除済みを落とすだけにして、無関係な写真を混ぜない。
     再読み込みは世代で追い越しを判定する。
  2. 索引は変更で「古いかもしれない」印を立て、裏で作り直す。**辞書は捨てない**
     （捨てると作り直しまで全フェッチに落ちて体感が戻る）。印がある間は要求のたびに
     現存を確かめ、取れた分は辞書へ入れる。
  3. アルバムは dirty 印を立て、次回の `loadOrScan()` と 500ms 後のデバウンスで再スキャン。
  判定は純ロジック `LibraryChangeFollowUp`（テスト対象）に切り出した。
- 教訓: **外部が持つ状態のスナップショットは、必ず陳腐化する**。キャッシュを置くときは
  「いつ捨てるか」を TTL ではなく**変更の通知**で決める（TTL は保険）。
  そして無効化のときにキャッシュを捨てるか、印だけ立てて使い続けるかは、
  「捨てた直後の代替経路がどれだけ遅いか」で決める。

## アップロード記録を待たずにバックアップを完了扱いにする

- 症状（潜在・コードレビューで指摘）: アップロード成功後の `BackupAssetRecord` 保存を
  fire-and-forget の `Task` で投げる一方、進捗台帳（UserDefaults）と `backedUpIDs` は
  **即座に成功扱い**にしていた。大量アップロードの直後や BGTask 終了時に保存タスクが残ったまま
  アプリが止まると、「次回は再アップロードされない（台帳に載っている）のに SwiftData 記録が無い」
  写真ができる。その写真はオフロード・端末アルバム合成・クラウド共有のどれからも辿れない。
- 対処: `upsertRecord` / `runnerSaveRecord` を **`async` かつ成否を返す**形にし、
  アップロードループから `await` する。**永続化できたときだけ**進捗台帳の ID へ加える。
  失敗した回は台帳へ入れないので、次回の実行で再検査され（実体は Dropbox にあるので
  409/hash 照合でスキップされ）記録だけが作り直される。
- 教訓: 「速いから」と非同期に切り出した書き込みは、**プロセスの寿命より長くなり得る**。
  台帳（＝次回の判断材料）を進めるのは、記録が確定してから。

## 古い 200 件が不適格だと、その先が永久にオフロードされない

- 症状（潜在・コードレビューで指摘）: オフロード候補の列挙が、検証の**前**に古い順 200 件で
  打ち切られていた。先頭が Live Photo・編集済み・iCloud 取得不可で埋まっていると、
  201 件目以降の適格な写真は `plan` にも `execute` にも渡らず、何度実行しても解放されない。
- 対処: 通信もデータ読み込みも要らない**構造的な不適格**（Live Photo・バックアップ後の編集）を
  `OffloadPlanning.isStructurallyIneligible` として切り出し、上限は**それを除いた数**で数える
  （ドライラン一覧にはスキップ理由つきで載せる）。台帳全体が不適格な場合に備えて
  走査自体の上限も設け、打ち切ったらログに残す（黙って切らない）。
- 教訓: 「上限つきの候補列挙」は、**上限を何で数えるか**で意味が変わる。
  ふるいの前で数えると、ふるいに落ちるものが先頭に溜まったとき先へ進めなくなる。

## メタデータ再送キューの保存失敗を隠していた

- 症状（潜在・コードレビューで指摘）: 再送キュー（`PendingMetadataStore`）の atomic write 失敗を
  握り潰し、呼び出し側へ成功したように返していた。写真本体は進捗台帳へ載って次回の対象から
  外れるため、**送信失敗に続いてキュー保存も失敗すると、人物・アルバム・位置情報が永久に欠落**する。
- 対処: `save` を `Bool` にし、失敗を伝える。バックアップの完了メッセージも
  「Done with warnings — … metadata lost: N」に分け、診断ログへ `metadata LOST=N` を残す
  （黙って「完了」と言わない）。
- 教訓: 再送キューは**最後の砦**。砦の書き込み失敗を握り潰すと、失敗の痕跡ごと消える
  （同レビュー群の 5 例目——「完了の記録は、完了を確認してから」）。

## 自己修復の「一時的な失敗」判定が SQLite のロック競合を見ていない

- 症状（潜在・Codex による自動レビューで指摘）: `StoreRecovery.isTransientCode` は
  `NSCocoaErrorDomain` と `NSPOSIXErrorDomain` しか見ておらず、**SQLite のロック競合**
  （`NSSQLiteErrorDomain` の `SQLITE_BUSY(5)` / `SQLITE_LOCKED(6)`）が来ると破損として扱う。
  別の `ModelContainer` やプロセスが一瞬ストアを掴んでいるだけでも、再構築可能なキャッシュは
  削除され、台帳は退避されて**空の台帳で起動**する。バックアップ済み判定を失うので
  二重アップロードが起きる。Cocoa の `NSFileLockingError(255)` も同様に漏れていた。
- 対処: `NSSQLiteErrorDomain` の BUSY / LOCKED と `NSFileLockingError` を一時的な失敗に分類する。
  一方 `SQLITE_CORRUPT(11)` は破損のままにする（何でも一時的にはしない）。
- 教訓: 失敗の分類は**ドメインごと**に必要。1 つのドメインだけ見て `default: false` にすると、
  「見ていないドメインの一時的な失敗」がすべて最悪の分岐（破壊）へ落ちる。

## 退避先の名前が衝突すると、壊れたストアが永久に残る

- 症状（潜在・同レビュー）: `quarantineURL` は `.corrupt` 〜 `.corrupt99` まで存在確認した後、
  **無条件に** `.corrupt-last` を返していた。それも存在すると既存の名前を返すことになり、
  呼び出し側の `moveItem` が失敗する。壊れたストアがその場に残るため再オープンも失敗し、
  **以後の起動が毎回インメモリに落ちる**（データが増えないまま動き続ける）。
- 対処: 連番の上限を外し、それでも埋まっていれば UUID 付きの名前で**必ず空きを作る**。
  「返す前に非存在を保証する」を関数の契約にした。
- 教訓: 「衝突しないよう連番」と書いた関数が、最後の分岐だけ**無条件**になっていた。
  フォールバックは往々にして検証されない——契約を破るのはたいていそこ。

## 完了ラッチに世代が無く、前の実行の通知が次の実行の枠を奪う

- 症状（潜在・同レビュー）: `CompletionLatch` は真偽値 1 つ＋`reset()` で、
  **どの実行からの通知か**を区別できなかった。実際に起こり得る順序は
  「A の期限切れが完了通知 → A 本体はキャンセル済みだが終了待ち → B が始まり `reset()`
  → **その後で A 本体が完了通知**」。すると (1) A が `setTaskCompleted` を二重に呼び、
  (2) ラッチが消費済みになって **B の正規の完了通知が黙って捨てられる**（B は OS へ
  完了を伝えられない）。
- 対処: `begin()` が世代トークンを返し、`completeOnce(token:)` が現世代の通知だけを通す。
- 教訓: 「1 回だけ」を保証する仕組みは、**何にとっての 1 回か**を持たないと使い回せない。
  使い回す前提の共有インスタンスには世代が要る（同レビュー群のバックアップ実行世代と同型）。

### 補足: この 3 件の見つかり方

これらは**別のモデルによるコードレビュー**（`MosaicSupport` の 2 ファイルに絞った 1 回）で
見つかった。いずれも直前のレビュー対応で書いたばかりのコードであり、
**書いた本人とは別の目で読ませる**価値がそのまま出た形になる。

## 並行するシャード更新が互いのメタデータを消す（オフロードマーカーの消失）

- 症状（潜在・自動レビューで指摘）: バックアップ情報またはオフロード済みマーカーが Dropbox から
  消える。後者が消えると、再インストール後にオフロード写真の台帳を再構築できない
  （マーカーの有無が「アプリが消した」と「ユーザーが消した」の唯一の区別なので、復元不能になる）。
- 原因: `MetadataShardWriter` の 2 つの入口——バックアップの追記（`applyEntries`）とオフロード
  マーカーの部分更新（`updateEntries`）——が、同じ `<deviceRoot>/.mosaic/meta/<YYYY-MM>.json` に対して
  **download → merge → upload(overwrite)** を行う。どちらも `@MainActor` だが、`await` をまたいで
  割り込むので MainActor でも実際にインターリーブする。`BackupEngine.start` と `executeOffload` の
  間に排他は無く、UI（バックアップ設定とオフロード設定）も互いを禁止せず、夜間バックアップは
  `isRunning` しか見ない。両者が同じ旧シャードを読むと**後着の overwrite が先着の変更を消す**。
  しかもオフロード側は `markOffloadMarkersUploaded` を済ませているため、消えたマーカーは再送されない。
- 対処: `MetadataShardLock`（actor・シャードパス単位の FIFO ハンドオフ）を追加し、
  download の直前に取り upload の応答後に解放する形で `applyEntries`（シャードごと）と
  `updateEntries`（関数全体）を包んだ。片方の read-modify-write が完了してからもう片方が
  読み直すので、両方の変更が最終内容に残る。失敗時の扱いは変えていない
  （バックアップ側は `PendingMetadataStore` へ、オフロード側は false を返して台帳に未送信で残す）。
- 関連: `Packages/BackupKit/Sources/BackupKit/MetadataShardLock.swift`（新規）/
  `MetadataShardWriter.swift` / テスト `MetadataDurabilityTests`「同じシャードへのバックアップ追記と
  オフロードマーカー更新が並行しても、両方が残る」（**状態を持つ**偽 Dropbox ＋ download 遅延で
  競合を再現。ロック無しでは落ちることを確認済み）。
- 教訓: **`@MainActor` は排他ではない**。`await` を含む read-modify-write は、同じアクター上でも
  インターリーブする。「最後に上書きする側が勝つ」通信手順（download→merge→upload）は、
  資源（ここではシャードのパス）単位のロックとセットでなければ成立しない。
- 残課題: ロックはプロセス内のみ。同一アカウントを複数端末で使う場合は端末フォルダで分離されて
  いるため衝突しないが、将来フォルダを共有するなら `rev` ベースの楽観ロックが要る。

## 古い一覧による照合が、照合中に上がった新しいバックアップ記録を消す

- 症状（潜在・自動レビューで指摘）: 実ファイルもアップロード済み ID も存在するのに SwiftData
  記録だけが消え、その写真を共有・オフロード・バックアップアルバムから辿れなくなる。
- 原因: `reconcileWithDropbox` は `listFolder`（再帰ページング＝実写真数によっては数秒〜数十秒）で
  リモート一覧を**固定**してから `reconcile` を実行する。その間にバックアップが 1 枚上げて
  `upsertRecord` すると、そのパスは古い一覧に無いので `reconcile` が記録を削除する。その後 runner が
  当該 ID を進捗台帳へ保存すると「台帳には済み ID があるが記録が無い」状態になり、`computePending` が
  済み判定で除外するため**自己修復しない**。加えて照合は `phase` を触らないので、照合中も
  `isRunning` は false のまま——別画面の「今すぐバックアップ」も夜間の自動起動も素通りする。
- 対処: 二層。(1) `BackupStore.reconcile(remote:listedAt:)` に一覧取得**直前**の時刻を渡し、
  `backedUpAt > listedAt` の記録は「この一覧が知り得なかった記録」として削除せず verified に入れる
  （アップロード時に hash 検証済みなので台帳からも落とさない）。(2) `BackupEngine` に
  `isReconciling` / `isBusy` を足し、`start` / `startNightlyIfEnabled` / 各ボタンを `isBusy` で塞ぐ。
- 関連: `BackupStore.swift` / `BackupEngine.swift` / `BackupDebugSection.swift` /
  `BackupSettingsView.swift` / テスト `ReconcileSafetyTests`（削除しない・従来どおり削除する
  2 ケースの回帰・排他）。
- 教訓: **スナップショットには「いつ撮ったか」を添える**。撮影後に生まれたものを「無い」と
  読むと、照合が修復ではなく破壊になる。UI のガードを `isRunning` のような**特定フェーズの
  述語**に頼ると、フェーズを持たない長時間処理（照合）がそのまま抜け道になる。

## 再レビューで出た 11 件（前回のレビュー対応で書いたコードの穴）

前回のレビュー対応で入れた修正そのものを読み直して見つかった一群。いずれも
「対処は正しいが、**適用範囲・寿命・所有者**を取り違えている」型の欠陥で、症状は
潜在（実機で気づきにくい）だが、起きたときは復旧できない種類のものが多い。

### 共有の墓標がアカウントをまたいで効く

- 症状: Dropbox アカウントを切り替えた直後（削除から 15 分以内）に、**新しいアカウントの
  同名フォルダが消える**。
- 原因: 墓標の鍵が Dropbox 上のパスだけだった。共有ルートは既定値が同じなので、別アカウントでも
  同名パスは普通に存在する。墓標は「持ち主」を持たずに 15 分生き続ける。
- 対処: 鍵を `アカウント指紋|パス` にし、読み書きとも指定アカウントぶんだけを見る
  （`ShareSettingsKeys.tombstoneKey`）。指紋は `accountFingerprint` seam でエンジンに注入する
  （生の accountId は扱わない——等値比較にしか使わないため）。
- 関連: `ShareSettingsKeys.swift` / `ShareSyncEngine.swift` / テスト `ShareTombstoneAccountTests`。
- 教訓: **「後で効く記録」には必ず持ち主を書く**。時間差で効く指示（墓標・保留キュー・再送）は、
  効くころには文脈が変わっている前提で設計する。

### メンバー更新だけが削除系の排他区間の外にいた

- 症状: 反映（コピー）が走っている最中に共有セットのメンバーを外すと、**記録を消した後に
  旧計画がコピー**して、誰の持ち物でもないファイルが共有フォルダに残る。
- 原因: `deleteSet` / `removeItems` は排他（`isMutating` ＋ `waitForSyncToPause`）に入るのに、
  `updateSetMembers` だけが入っていなかった。反映は**先に読んだ計画**でコピーするため、
  記録の変更はコピーを止めない。
- 対処: `updateSetMembers` も同じ区間に入れる。作成経路が既に排他を持っている場合を考え、
  `ownsExclusion` で二重取得を避ける。止まらなければ `.syncBusy` で諦める（黙って進めない）。
- 関連: `ShareSyncEngine.swift` / テスト `ShareMemberUpdateExclusionTests`
  （反映を走らせたまま外していないことを `isSyncing` で確認）。

### 未コピーの写真を外しても、発行済みジョブが後から作る

- 症状: 共有セットから外した写真が、しばらくして共有フォルダに現れる（記録は無いので孤児になる）。
- 原因: 「まだコピーされていない（`sharedPath == nil`）」は**その瞬間の記録**でしかない。
  クライアント側のポーリングをやめても、Dropbox 側の `copy_batch` はサーバーで完走する。
- 対処: フォルダ墓標と同じ仕組みで、**予定コピー先（`<setフォルダ>/<ファイル名>`）にファイル墓標**を
  置く。掃除は `sweepDeletedFolders` がフォルダ墓標と同じ規則で行う（100 パスずつ）。
- 関連: `ShareSyncEngine.swift` / `ShareSettingsKeys.deletedFiles` / テスト
  `ShareMemberUpdateExclusionTests`「未コピー分を外すと、予定コピー先に墓標が残る」。
- 教訓: **こちらが諦めても、サーバーは諦めない**。非同期ジョブにキャンセル API が無い相手には、
  「後から現れたら消す」側で辻褄を合わせる。

### 保留メタデータのキューが、アカウント・保存先をまたいで混ざる

- 症状: アカウントや保存先を切り替えると、**前の保存先向けの人物名・位置・アルバム**が
  現在の保存先へ書かれる。
- 原因: 再送キューが `BackupPendingMetadata.json` 1 本だった。
- 対処: `アカウント指紋|保存先` から名前空間を作る（`PendingMetadataStore(account:folder:)`）。
- 関連: `PendingMetadataStore.swift` / `BackupRunner.swift` / `BackupEngine.swift` /
  テスト `PendingMetadataNamespaceTests`。

### 上げる写真が無い回に、保留メタデータが滞留し続ける

- 症状: 人物名・位置・アルバムが欠けたまま直らない。写真が増えるまで再送が走らない。
- 原因: `run(folder:)` は「差分が空」で早期 return しており、その前に再送を試みていなかった。
  メタデータは実体と違い**失敗しても次回の対象にならない**（実体を上げた時点で ID が台帳に載る）
  ため、滞留は永久化する。
- 対処: 早期 return の前に再送する。ただし**カタログは触らない**——この経路は albums/people の
  索引を作っていないので、空の索引で上書きすると既存のカタログから名前が消える。
- 関連: `BackupRunner.drainPendingMetadata(folder:pendingStore:)` / テスト
  `PendingMetadataDrainTests`（キューが空になる・カタログを書かない・失敗分は残る）。
  ※ 早期 return の**呼び出し位置**そのものは PhotoKit 依存のため単体テスト対象外。

### オフロードマーカーを撮影月だけで束ねていた

- 症状: 別フォルダ（旧レイアウト・端末フォルダ・保存先変更の前後）の写真が同じ撮影月に混ざると、
  **全部が先頭要素の親フォルダのシャードへ書かれ**、しかも全件が「送信済み」になる。本来の
  フォルダのマーカーは永久に欠落する（＝再インストール時に復元不能）。
- 対処: 束ねる鍵を `フォルダ|シャード` にする。
- 関連: `OffloadService.uploadOffloadMarkers` / テスト `OffloadMarkerGroupingTests`。

### 台帳走査を出力件数で打ち切っていた

- 症状: 古い順の先頭が Live Photo・編集済みで埋まっていると、その先の適格な写真に到達できず、
  **何度実行してもオフロードされない**。
- 原因: 上限を「適格数」で数える修正は入っていたが、保険として残した `out.count >= scanLimit * 10`
  が同じ打ち切りを再現していた（不適格分も出力に積んでいたため）。
- 対処: 走査は台帳の最後まで進める（記録はメモリ上にあるので安い）。一覧表示のための不適格は
  50 件で頭打ちにし、省いた件数はログに残す。走査ロジックは純関数
  `OffloadPlanning.scanCandidates` に切り出した。
- 関連: `BackupEngine+Offload.swift` / `OffloadService.swift` / テスト `OffloadLedgerScanTests`。
- 教訓: **「保険」の打ち切りが本命の不具合を再現していないか**を見る。上限を 2 か所で数えると、
  片方だけ直しても効かない。

### 終わった旧世代が、次の実行のハンドルを消す

- 症状: 夜間処理 A をキャンセル → B が開始 → その後 A が終了、の順で、A が `currentWork` を
  nil にして **B のハンドルを消す**。以後フォアグラウンド復帰でも B を止められず、
  実行中表示も「走っていない」に見える。
- 対処: 世代トークンつきのハンドル（`MosaicSupport.GenerationHandle`）にし、**自分が現行のときだけ**
  手放す。明示キャンセルは世代に関わらず手放す。
- 関連: `HeavyWorkScheduler.swift` / `GenerationHandle.swift`（新規）/ テスト `GenerationHandleTests`。
- 教訓: `CompletionLatch` と同型の誤り。**共有スロットは「誰のものか」を持たないと使い回せない**。

### スキャン中に来たライブラリ変更を、誰も拾い直さない

- 症状: アルバム走査の実行中に写真ライブラリが変わると、表示中のアルバムが古いまま残る
  （次に画面を開き直すか TTL が切れるまで直らない）。
- 原因: 走行中の変更は「印を立てる」だけで、そのスキャンの完了時に印を見ていなかった。
- 対処: 完了時に印を見て走り直す。判断は純関数 `LibraryChangeFollowUp.scanAction(isDirty:isScanning:)`
  に出し、変更通知・完了の両方が同じ規則を使う。
- 関連: `LocalAlbumScanner.swift` / `LibraryChangeFollowUp.swift` / テスト `ScanFollowUpTests`。

### 低品質の顔を分離すると、存在しないクラスタを指す

- 症状: 低品質（品質フロア未満）の顔をユーザーが「別の人物」へ分けても、その人物が
  ピープル一覧に出てこない。顔だけが**存在しないクラスタ ID** を指して迷子になる。
- 原因: 低品質顔は重心を汚さないため membership だけで入れる（`contributes: false`）が、
  `addToCluster` は寄与しない顔ではクラスタを作らずに返る。新規クラスタ側にはまだ実体が無い。
- 対処: **新しいクラスタを作る場合は品質に関わらず種にする**（`reassignFace` は新規クラスタ判定、
  `splitCluster` は 1 枚目）。ユーザーが明示的に分離した顔なので、種にする根拠もある。
- 関連: `FaceStore+Edit.swift` / テスト `FaceStoreLowQualitySplitTests`。

### 退避ファイルの世代刈りが WAL/SHM を取りこぼす

- 症状: 破損台帳の退避（quarantine）が消えずに溜まり続ける。一方で**現役世代の
  `-wal` / `-shm` が消える**（件数をファイル単位で数えていたため）。
- 原因: 退避名は `<store>.corrupt` だけでなく `<store>-wal.corrupt` / `<store>-shm.corrupt` も
  作られるのに、刈り取りは `<store>.corrupt` 前缀のファイルだけを新しい順に 3 件残していた。
- 対処: `<store>` で始まり `.corrupt` を含むものを対象にし、**世代（corrupt / corrupt2 …）単位**で
  古いものから消す。
- 関連: `ResilientModelContainer.swift` / テスト `QuarantinePruneTests`（実ディレクトリに
  4 世代 × 3 ファイルを作って刈る）。
- 教訓: SQLite の単位は 1 ファイルではない（本体・WAL・SHM の 3 点セット）。**まとめて扱う対象は
  まとめて数える**。

### この 11 件に共通する形

「直したはずの対処が、**別の軸**で同じ穴を開けている」。適用範囲（アカウント・保存先・フォルダ）、
寿命（発行済みジョブ・墓標）、所有者（世代）のいずれかが抜けると、対処は成立しない。
テストも同じ軸で書く——今回は 11 件すべてについて、**修正前のコードで落ちること**を確認した
（保留メタデータの呼び出し位置だけは PhotoKit 依存のため対象外）。

## 前面で 78 秒メインが止まる（diagnostics-56・原因は次ログ待ち）

- 症状: 実機で操作を受け付けなくなり、ユーザーがアプリを終了。
- 実測: 22:06:01〜22:07:19 の約 78 秒、**前面でメインがほぼ完全に停止**。ウォッチドッグの
  ping は 200ms 間隔（正常時は 10 秒あたり 46〜49 回）に対し、この間は **2〜4 回**。
  約 6 秒のハングが 5 回続く形（9589 / 6370 / 6251 / 6200 / 6106 ms）で、ログ全体 5.5 時間の
  hang 10 件のうち 9 件がこの 1 分に集中している。直前に 25 分のプロセス中断があり、
  停止は**前面復帰の瞬間**から始まっている。
- **原因は未特定**。決定的な証拠が無い:
  - 停止中はログが出ない（`PERF hang` 以外の行がゼロ）。ログを書くのもメインの仕事のため。
  - `people.load.favorites 6124.6ms` は**症状であって原因ではない**。実体は
    `Task.detached(.utility)` で、メインが詰まれば `.utility` は飢餓する。復帰後の同じ処理は
    177ms で終わっている。
  - MetricKit（ADR-106）の OS 採取スタックは、この 5.5 時間のログに 1 行も届いていない
    （診断ペイロードの配信は 1 日 1 回まで）。
- 対処（2 本）:
  1. **観測手段を足した**（ADR-117）: ハングの継続中にメインのスタックを自前で採る
     （`PERF hang.stack` 行）。次の実機ログで犯人を名指しできる。
  2. **確実な欠陥を 1 件修正**: 前面復帰時の譲りが 13 秒遅れていた（下記）。
- 教訓: 「測ってから直す」（CLAUDE.md 性能原則 5）は、**測る手段が無いときは測る手段を作る**まで
  含む。ここで推測に基づく修正を積むと、ADR-106 で一度通った道（推測での修正 2 回・再発）を繰り返す。

### 前面へ戻っても顔スキャンが 13 秒止まらない

- 症状（上と同じログ）: `faces: stopScan (foreground return)` が 22:06:01、実際にスキャンが
  終わったのは 22:06:14＝**13 秒後**。その間 `face.photoMs=2(Σ10300.3ms)`＝写真 2 枚で 10.3 秒を
  費やしている（健全時は 1 枚 15〜80ms）。
- 原因: `FacePerceptionAdapter.detectFaces` のキャンセル判定が**ループの末尾**、つまり
  「画像ロード → 推論」の**後**にしか無かった。呼び出しは 1 キーずつ（`processUnit`）なので、
  末尾の判定は事実上何も止めない。クラウド写真のロードは Dropbox の往復で、この時間帯は
  1 リクエスト 7.5 秒かかっていた。結果として、ユーザーが戻った後も回線と ANE を握り続ける。
- 対処: **重い段の前**で降りる——(1) 画像を取りに行く前、(2) ロード完了直後（＝推論に入る前）。
  ANE ゲートを掴んでからでは、他の解析も道連れになる。抜けた写真は結果に載らないので、
  下流は「未解析」として次の窓に回す（ADR-92 と同じ扱い＝走査済みにしない）。
- 関連: `MobileCLIPKit/FacePerceptionAdapter.swift`。
- 教訓: 「操作が来たら即譲る」は**判定を置く位置**で決まる。ループの末尾に置いた
  `Task.isCancelled` は、1 単位ずつ呼ばれる実装では飾りにしかならない。
- 残課題: 進行中のクラウド往復そのものは中断できない（`cloudAnalysisImages` がキャンセルを
  受け取らない）。譲りの遅れは最大 1 往復ぶん残る。

## 取得完了順のマージで、凍結された v1 メタデータが新しい v2 を上書きする

- 症状: 移行済みバックアップで、人物名・アルバム・お気に入り・オフロード情報（`offloadedAt`）
  などが新しい v2 の値ではなく**古い v1 の値**として表示されることがある。毎回ではなく、
  通信の揺らぎで再現したりしなかったりする。
- 原因: `DropboxPhotoStore+BackupMetadata.loadBackupMetadata` は対象 JSON を
  「各ルートの v1 `.mosaic/metadata.json` → そのルートのシャード群」の順で `jsonPaths` に積むが、
  取得は `withTaskGroup` の**並列**で、結果を `for await part in group { out.append(part) }` と
  **完了順**に配列へ入れていた。その配列を後勝ちで `merging` するため、v1 のダウンロードが
  遅れて完了すると v1 が v2 を上書きする。v1 は ADR-38 で**凍結**され、以後の更新は v2 シャードに
  だけ書かれる（`BackupRunner`）ので、同一パスの v1/v2 エントリは実際に値が異なる。
  ファイル冒頭にあった「重複キーは同一エントリなのでマージ順序に意味はない」というコメントは、
  v1 凍結・v2 追記という現在の仕様と矛盾しており、**前提そのものが誤り**だった。
- 対処: 取得結果を完了順ではなく `jsonPaths` の並び順で確定させる。タスクグループの要素を
  `(index, DropboxBackupMetadata?)` にし、`[DropboxBackupMetadata?](repeating: nil, count:)` の
  該当スロットへ代入する。マージ本体は純関数 `BackupMetadataMerging.merge(ordered:)` へ切り出し
  （nil を飛ばして先頭から順に `merging`）、オフメイン（`Task.detached`）で呼ぶ性能特性は維持。
  誤ったコメントは「順序に意味がある＝後ろほど新しい」へ書き換えた。
- 関連: `DropboxCore/Store/DropboxPhotoStore+BackupMetadata.swift` /
  `DropboxCore/Models/BackupMetadataMerging.swift` /
  `DropboxCoreTests/DropboxBackupMetadataTests.swift`（完了順を入れ替えても結果が同一であること・
  v1 のみ/v2 のみ/複数ルートで全エントリが残ることを検証）。ADR-38。
- 教訓: **並列取得の結果を「届いた順」に積んだ時点で、順序の意味は失われる**。マージが
  後勝ちなら、順序は index で復元してからでないと正しくない。「重複キーは同じ値だから順序は
  どうでもいい」という前提は、片方のファイルが凍結された瞬間に崩れる——前提を書いた
  コメントは、仕様が変わったら一緒に検算する。

## キャンセルしたはずのキャッシュ読み込みが、切断後の一覧を復活させる

- 症状: Dropbox を切断して一覧が消えた後、旧アカウントのクラウド写真が再び一覧へ現れる。
  アカウントを切り替えた場合は、新しい一覧を旧一覧が上書きし得る。
- 原因: `resetLoad()` / `clearCache()` / アカウント切替は `loadTask?.cancel()` してから
  `items = []` するが、**`cancel()` では `reflectCachedItems` の待機点を止められない**。
  `cache.currentItemsRevision()` / `cache.cachedItems()` は actor 呼び出しでキャンセルを見ず、
  署名計算＋刻印の `Task.detached` は親のキャンセルを継承しない。したがって全件変換中に
  切断・切替が入ると、リセット後に `lastReflectedRevision` / `items` / `loadStatus` /
  `debugInfo` の代入が着地する。加えて `loadItems()` の後始末が無条件の `loadTask = nil` で、
  リセット後に始まった**新しい**読み込みの登録まで消していた（合流の取りこぼし）。
- 対処: 読み込みの**世代**（`loadGeneration`）を導入し、リセット・キャッシュ消去・アカウント切替で
  **items をクリアしたり cache を消したりする前に**インクリメントする。`reflectCachedItems` は
  冒頭で `(世代, accountId)` の札を捕まえ、**各 await の直後**に純ロジック
  `DropboxPhotoStore.shouldApplyLoad(captured:currentGeneration:currentAccountId:isCancelled:)`
  で適用可否を判定し、false なら**何も代入せずに**早期 return する。あわせて `loadItems()` の
  後始末を `if loadTask == task { loadTask = nil }` に変え、古い呼び手が新しい登録を消さないようにした。
- 関連: `DropboxCore/Store/DropboxPhotoStore.swift` /
  `DropboxCoreTests/DropboxPhotoStoreLoadGuardTests.swift`。
- 教訓: **`Task.cancel()` は「止まる」保証ではない**。actor への await も detached タスクも
  キャンセルを見ないので、止めたい対象が「代入」なら、代入の直前に**世代／所有者の照合**を
  置くしかない。cancel は速く終わらせるための最適化、照合が正しさの担保。
- 残課題: 同一アカウントの同時 `loadItems()` が 1 読み込みへ合流し一度だけ反映されることは
  `loadTask` の合流と同一タスク判定で担保しているが、`DropboxPhotoStore` は cache/認証を
  注入できず実インスタンスを組めないため自動テストが無い（コードレビューでの確認に留める）。

## 「見覚えのない写真が一覧に出る」を実機で切り分けられなかった

- 症状（実機・diagnostics-57）: 「すべての写真」に古い写真が大量に出るようになった。
- **原因は特定できていない**。決定的な材料が無いため。ログには「一覧が何件か」は出るが
  **どの写真がどこ由来か**が一切出ず、画面にも出ない。共有コピー・バックアップ・別フォルダの
  どれ由来かを区別する手段が無い。
- ログから分かった事実（原因の候補を絞るところまで）:
  - **バックアップメタデータは表示に無関係**。`backupMetadata` の用途はオフロード台帳の
    再構築（`rebuildOffloadLedgerIfEmpty`）とデバッグ表示だけで、一覧の中身を決めていない。
    直前に入れた「取得完了順で v1 が v2 を上書きする」修正は、この症状の原因ではない。
  - 同期のソースが `/`（Dropbox 全体）。共有コピー（`/MosaicShare/…`）も走査対象に入る。
    これを隠しているのは**表示除外の接頭辞だけ**（`ShareVisibility.apply`）。
  - その除外は、自分の共有ルートが**家族フォルダとして登録されていると丸ごと無効**になる
    （`family.contains(root) ? [] : [root]`）。受信側の設定ひとつで送信側の隠蔽が外れる。
  - 共有の反映が進行中で、`'金居家' items=6073 copy=4297 present=4578`。既に 4,578 枚の
    コピーがクラウド側に存在する。
  - フォルダ移行が失敗している: `move '/MosaicShare/金居家' → '/MosaicShare/iPhone-8D1681/金居家' failed`。
- 対処（観測手段の追加）: フル画面の情報パネルに**実体の所在**を出す（`PhotoSourceLocation`）。
  端末なら localIdentifier、クラウドならフルパスと親フォルダ。長押しでコピーできる。
  「この写真はどこにあるのか」に画面で答えられれば、由来フォルダはその場で分かる。
- 関連: `PhotoSourceKit/Interface/PhotoItem.swift`（`sourceLocation`）/ `PhotoInfoPanel` /
  `DropboxFileItem+PhotoItem` / `MergedPhotoItem`（合成 id ではなく**実体へ委譲**）。
- 教訓: 一覧に「何が入っているか」を人が確かめられない設計だと、混入系の不具合は
  ログをいくら足しても切り分けられない。**画面で答えられるようにする**のが先。

### 補足: 自前のハングスタック採取が実際に効いた

同じログに `PERF hang.stack` が出ており、ADR-117 の採取が実機で動くことが確認できた。
出ていたのは `PhotoPageView.currentItem` → `MergedPhotoItem.id.getter` の連なりで、
**ページビューが表示のたびに配列を線形走査して現在位置を求めている**（id は毎回
`"L-…"`/`"C-…"` を文字列で組み立てる）。数万件の一覧では効く。未対処。

## フル画面ビューが 18 秒固まる（合成 id の線形走査）

- 症状（実機 diagnostics-58）: フル画面ビューが重すぎて使い物にならない。前面のハングが
  28 回、最大 **18.0 秒**（18055 / 17989 / 17341 ms …）。
- 原因: **採取したメインスレッドのスタックが犯人を名指しした**（ADR-117 の採取が実機で
  初めて役に立った例）。

      PhotoPageView.currentItem.getter
        → closure #1 (A.Item) -> Bool
          → MergedPhotoItem.id.getter : Swift.String

  `currentItem` が `allItems.first { $0.id == currentID }` で**毎回全件を線形走査**していた。
  しかも `MergedPhotoItem.id` は `"L-\(item.id)"` を**呼ばれるたびに組み立てる計算プロパティ**。
  9 万件の一覧では 1 回の解決で 9 万個の String を作って捨てる。`currentItem` は上部ラベル・
  下部バー・お気に入り判定から複数回呼ばれ、`init` / `recenterWindowIfNeeded` /
  `schedulePrefetch` / 末尾判定も**それぞれ独立に**同じ走査をしていた。
- 対処: 現在位置（`Int`）を `@State` で持ち回り、当たっていれば探索しない
  （`PagingIndex.resolve(_:id:hint:)`）。一覧が入れ替わって当たりが外れたときだけ探し直すので
  ズレても壊れない。位置の解決は `onChange(of: currentID)` で 1 回だけ行い、以降は使い回す。
  隣へめくった直後は当たりの ±1 なので探索はほぼ起きない。
- 実測（テスト）: 10,000 件で `id` の読み出し（＝文字列生成）が **7,001 回 → 1 回**。
- 関連: `PhotoSourceKit/Support/PagingIndex.swift`（新規・純ロジック）/ `PhotoPageView` /
  テスト `PagingIndexTests`（修正前のコードで落ちることを確認済み）。
- 教訓: **「id が安い」という前提を疑う。** 合成 id（`"L-…"`/`"C-…"`）は等値比較のたびに
  確保が走る。`first { $0.id == x }` は要素数だけでなく **id の値段**との積で効いてくる。
- 残課題: グリッド側にも同型のスタックが出ている
  （`PhotoCollectionView.Coordinator.update` → `gridIdentitySignature` が全件の id を
  `LazyMapSequence` で舐める）。未対処。

## バックアップコピーが「すべての写真」に二重に出る

- 症状（実機 diagnostics-57/58）: 「すべての写真」に古い写真が大量に出るようになった。
  フル画面の所在表示（前項で追加）で確認したところ、実体のパスは `/MosaicPhotos/…`＝
  **この端末のバックアップフォルダ**だった。
- 原因: バックアップフォルダは**意図的に** Dropbox の同期ルートに入っている（`RootView`）。
  オフロード（端末から消した）写真の「クラウド側の代替」を、ソースフォルダ設定に関わらず
  表示できるようにするため（ADR-40）。ところが `MergedPhotoStore` に**重複排除が無く**、
  端末にまだ有る写真まで「端末の 1 枚」＋「クラウドの 1 枚」で二重に出ていた。
  バックアップが古い写真を上げ進めるほど、古い写真が次々に現れる見え方になる。
- 対処: バックアップコピーは**端末に原本が無いときだけ**出す（`BackupCopyHiding`）。
  台帳（Dropbox パス小文字 → localIdentifier）を seam で受け取り、その localIdentifier が
  端末の一覧に有るコピーを隠す。オフロード済みの写真はクラウドのコピーが唯一の実体なので
  そのまま出る＝ADR-40 の代替表示は保たれる。
  ⚠️ **対応が分からないものは隠さない**（台帳が空・localIdentifier を持たない旧記録）。
  重複するより、隠して「無い」と思わせる方が取り返しがつかない。
- 関連: `PhotosFeatureKit/BackupCopyHiding.swift`（新規・純ロジック）/ `MergedPhotoStore`
  （`backupCopyIndexProvider` seam・`refreshBackupCopyIndex()`）/ `RootView`（結線）/
  テスト `BackupCopyHidingTests`。
- 教訓: 「クラウドにも実体がある」ことと「クラウドの実体を**見せる**」ことは別。
  代替表示のために同期範囲へ入れたものは、**原本が生きている間は出さない**と決めておかないと、
  ライブラリ全体が二重になる。
- 残課題: 隠す判定は台帳が育つ速度に依存する。バックアップ直後は台帳に載るまでの間だけ
  二重に見えることがある（`refreshBackupCopyIndex()` は起動時に 1 回）。

### 続き: 二重パスの疑いと、確認できなかった理由

報告されたパスが `/mosaicphotos/iphone-8d1681/mosaicphotos/iphone-8d1681/img_2217.jpg`
＝**端末フォルダの部分が 2 回**現れていた（手入力のため転記誤りの可能性あり）。

**確認できなかった。** バックアップの保存先は `addLog`（アプリ内ログ）にしか出しておらず、
共有される診断ログには 1 行も残っていない。3 セッション分のログを見ても `/MosaicPhotos` 由来の
パスは 1 つも出てこない。「どこへ上げているか」が後から追えない状態だった。

対処 2 つ:
- **保存先を診断ログへ出す**（`backup: root=… (setting=…)`）。次回のログで確定できる。
- **端末フォルダの付与を冪等にする**（`deviceBackupRoot(for:deviceFolder:)`）。
  結果が設定へ書き戻る・既に端末フォルダ配下のパスを渡される、のどちらでも二重にならない。
  二重になると**同じ写真が別パスへ再アップロードされる**（台帳に無いパスなので未バックアップ
  と判定される）。一覧には旧パスと新パスが並び、「古い写真が急に増えた」ように見える——
  今回の症状と一致するので、確定していなくても塞ぐ価値がある。
- 関連: `BackupEngine.deviceBackupRoot` / テスト `DeviceBackupRootTests`。

## サムネイルの密表示が重い（ID 指紋をメインで取り直していた）

- 症状（実機 diagnostics-59）: サムネイルを密に表示するモードでロードが重い。
  前面のハングが 38 回、最大 **19.6 秒**。
- 原因: 採取したメインスタックがグリッドを名指しした。

      PhotoCollectionView.updateUIView
        → Coordinator.update(items:…)
          → gridIdentitySignature
            → MergedPhotoItem.id.getter : Swift.String
              → LocalPhotoItem.id.getter : Swift.String   （PHAsset.localIdentifier を読む）

  指紋を ID 列全体から作るのは正しい（件数と両端だけでは入れ替わりを取りこぼす）。
  問題は**取り直す頻度**だった。
  1. **ズームで列数を変えるだけでも `updateUIView` は走る。** 中身が 1 つも変わっていないのに、
     86,262 件ぶんの文字列生成と `PHAsset.localIdentifier` の読み出しをやり直していた。
     密表示は列数変更で入るので、まさにこの操作で最も重くなる。
  2. **同期中は 0.4 秒ごとに統合一覧が再構築される。** 内容は変わらないことがほとんどだが、
     `items` へ代入するたびに配列の実体が変わり、グリッドは「変わったかもしれない」として
     指紋を取り直していた。
- 対処:
  - グリッド側: **同一実体（COW の同一バッファ）なら指紋を再計算しない**（`sharesStorage`）。
    同一バッファなら中身は必ず等しい。違っても中身が同じことはあり得るので、「同じ」と
    言えたときだけ省く＝偽陰性は安全側（ただ計算するだけ）。⚠️ 比較側は前回の配列を
    **保持し続ける**こと（手放すとバッファが解放され、別配列が同じアドレスに載り得る）。
  - 統合ストア側: 指紋を**オフメインで**取り、同じなら `items` に代入しない。
    メインで取ると id の文字列生成がそのまま画面の停止時間になる。
- 実測（このログ）: `grid.layout 81ms cols=15` / `grid.snapshot build=1188ms items=86262`。
  スナップショットの作り直し自体は内容が変わったときだけなので残す。
- 関連: `PhotoSourceKit/Support/GridSignature.swift`（`sharesStorage`）/ `PhotoCollectionView` /
  `PhotosFeatureKit/MergedPhotoStore`（`setItems(_:generation:signature:)`）/
  テスト `SharesStorageTests` / `MergedSignatureTests`。
- 教訓: 前項（フル画面の線形走査）と**同じ形**。合成 id は等値比較・ハッシュのたびに確保が走る。
  「正しい指紋を作る」ことと「毎回作り直す」ことは別問題で、後者は呼ばれる頻度で決まる。
- 残課題: 実測でメモリが **1032MB** に達している（jetsam 圏内）。今回は落ちていないが未調査。

## 密表示でメモリが 1GB を超えて落ちる（取得の同時実行に上限が無かった）

- 症状（実機 diagnostics-59）: サムネイルを密に表示するモード（15 列）へ切り替えた直後から
  メモリが **164MB → 1032MB** へ急増し、アプリが落ちた。メモリ圧迫イベントは 1 件も出ていない
  （jetsam は警告を挟まずに殺すことがある）。
- 原因: カウンタが示していた——10 秒間で `thumb.cacheMiss=1072`。ミス 1 件につき
  `PHImageManager.requestImage` が 1 本走るが、**同時実行に上限が無かった**。
  しかも取得サイズは**最低 640×640**（小さい targetSize だと一部写真で向きが狂う
  PHImageManager の挙動を避けるための下限・実測で 640 なら解消）。

      640 × 640 × 4 バイト ≒ 1.6MB／枚 × 1,000 枚同時 ≒ 1.6GB

  取得後に `resizedUp` がセルサイズへ縮小する際もう 1 枚確保する。列を増やすほど可視セルと
  先読みが増えるので、**密にするほど落ちやすい**という形になっていた。
  （待ち行列も破綻していた: `cache.thumb.queueMs` の平均待ちが 4.6 秒、`cancelled=788`。）
- 対処: **同時に走らせる `requestImage` の本数を絞る**（`PhotoRequest.limiter`・
  `min(16, max(4, コア数×2))`）。取得サイズは向きの都合で下げられないので、
  **同時に持つ枚数**を絞るのが正しい対処。16 本なら約 26MB＝山が有界になる。
  順番待ちの間に画面外へ去った要求は、待ち解除の直後に `Task.isCancelled` で降りる
  （密表示ほどこれが多く、1 枚も確保せずに済む）。
- 関連: `LocalPhotoCore/PhotoRequestLimiter.swift`（新規）/ `LocalPhotoStore+PhotoStore`
  （`thumbnailStages` と `requestThumbnail` の両経路）/ テスト `PhotoRequestLimiterTests`。
- 教訓: **「小さく見えているもの」の実サイズを疑う。** 26pt のセルでも、向き対策の下限で
  640px を確保していた。表示サイズと確保サイズが乖離している所は、同時数が効いてくる。
- 残課題: Dropbox 側の `cachedItems()` が初回同期中に 72,935 件を数秒おきに丸ごと実体化して
  いる（`cache.fetchItems` 1〜2 秒）。ピークの底上げに効いているはずで、未対処。

## 起動直後・設定画面で固まる（メインが SQLite で止まっている）

- 症状（実機 diagnostics-60）: 起動直後のトップ画面と設定画面で固まる。前面のハングが 11 回、
  **約 9〜10 秒が 5 回連続**（11:57:27 / :37 / :48 / :58 / 11:58:15）。ログはその途中で終わっている。
- 分かったこと: **メインスレッドが SQLite で止まっている**。採取したスタックの先頭が

      libsystem_kernel  pread
      libsqlite3        sqlite3_step …
      CoreData          <redacted> ×5

  停止の直前は前面復帰（11:57:15 `scene: active` → `faces: stopScan`）。diagnostics-56 の
  78 秒停止と**同じ形**で、あのとき「原因未特定」としたものに初めて手がかりが付いた。
- **呼び出し元は特定できていない。** 採取が 16 フレームで、システム側の連なりだけで枠を使い切り、
  アプリのフレームに 1 つも届いていなかった。
- 調べて**外した**もの:
  - SwiftData の `@ModelActor`（`BackupStore` / `FaceStore` / `AutoAlbumStore` / `TagStore`）は
    すべてオフメイン生成。本番でメイン生成される経路は無い。
  - `LocalAssetIndex` の主経路も外した。索引は 11:44:42 に構築済みで、以後 `invalidated` の記録が
    0 件＝辞書引きで済んでおり、メインでの `fetchAssets` へは落ちていない。
  - CoreData は SwiftData だけでなく**写真ライブラリ（PhotoKit）**も使う。どちら由来かも未確定。
- 対処（観測手段の改善）: 採取を **96 フレーム**まで深くし、出力は
  「先頭 4 フレーム（何で止まっているか）＋**自アプリのフレーム**（誰が呼んだか）」に絞る
  （`MainThreadWatchdog.interestingFrames`）。中間のシステムフレームは読み手の役に立たず、
  枠を食うだけだった。次のログで呼び出し元が名指しできる。
- 関連: `MosaicSupport/MainThreadStack.swift`（capacity 96）/ `MainThreadWatchdog` /
  テスト `InterestingFramesTests`。
- 参考: 人物数がこの間に **276 → 1,316** に増えている（顔スキャンの進行）。トップ画面の
  行数・カバー読み込みが増えているので、関係する可能性はあるが未確認。

## 「次の人へ」で画面が変わらない（候補生成が人物数ぶんの fetch）

- 症状（実フィードバック）: ピープルの一括レビューで「次の人へ」を押しても、なかなか画面が
  変わらない。固まっているように見える。
- 原因は 2 つ:
  1. **候補生成が人物数に比例して重い。** `batchReviewItem` は対象クラスタごとに
     `faces(inCluster:)` を呼んでおり、人物が **1,316 人**まで育ったライブラリでは
     **1 画面あたり 1,316 回の SwiftData fetch** が走っていた。人物が増えるほど遅くなる＝
     機能が育つほど使えなくなる形。ADR-88 で同じ理由の射影クエリ
     （`memberRefKeys(inCluster:)`）を用意していたが、この経路は取りこぼしていた。
  2. **待っていることが画面に出ない。** `isLoading = true` の直後に処理へ入っており、
     SwiftUI が描画する前に待ちへ入るため「押したのに何も起きない」に見えた。
     同じ問題への対処（`runShowingBusy`＝表示を確定させるまで数フレーム譲る）は
     既に用意されていたのに、この画面では使っていなかった。
- 対処:
  - 顔は **1 回で取る**（`allFacesInClusters()`）。束ねるのはメモリ上で行う。
    **選ばれる候補・しきい値・順序は一切変えていない**（精度は台帳の対象なので触らない）。
  - 画面は**先に切り替える**。直前の人物のグリッドを消し（`item = nil`）、`runShowingBusy` で
    スピナーの表示を確定させてから探し始める。文言も「似た人を探しています…」にした。
  - `people.batchReview.load` を計測点として追加（人物数に対してどう伸びるかを実機で残す）。
- 関連: `FaceStore.allFacesInClusters` / `FaceStore+Review.batchReviewItem` /
  `FaceBatchReviewView.load` / テスト `BatchReviewCandidateTests`（束ね直しがクラスタ単位の
  取得と一致すること）。
- 教訓: **「1 件ずつ引く」は件数が小さいうちは見えない。** 機能が育つ（人物が増える）と
  初めて表に出るので、全件を走査する処理は最初からまとめて取る。
  待ち時間を消せない場合でも、**待っていることを見せる手当ては別途要る**——
  仕組み（`runShowingBusy`）があっても、使われていなければ無いのと同じ。
