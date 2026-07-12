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

## Florence キャプションが実機で全写真同一の無関係テキストになる（ANE の cross-attention）
- 症状: VLM を Florence-2-base に替えたら、実機で生成されるキャプションが**どの写真も "Trump doing from…" 等の同一・無関係テキスト**になる（「説明を確認」画面で発覚）。Mac（coremltools・CPU_AND_NE）では正しく "The image shows a gas pump with a sign that reads Please Prepay…" が出る。
- 原因: **実機 Neural Engine（ANE）が Florence の encoder-decoder の cross-attention を正しく計算しない**。同梱モデル・Swift の貪欲デコード・トークナイザ復号はすべて正しく（Mac Core ML で生成IDが `[0,133('The'),2274('image')…]` と検証済み・base-vocab/Swift-merge どちらの復号も一致）、実機 `.all`（ANE 優先）でのみ壊れる。SmolVLM は**デコーダ単独**だったため ANE で問題が出ず、encoder-decoder に替えて初めて顕在化した。切り分け: (1) Mac Core ML で ID と復号が正しいことを確認 → Swift ロジック/資産は無罪、(2) 差分は実機 ANE のみ → ANE 起因と断定。
- 対処: **VLM だけ ANE を避けて CPU+GPU で走らせる**（`CoreMLModelLoader.makeConfiguration(avoidNeuralEngine:)` を追加し `computeUnits = .cpuAndGPU`）。CLIP/顔は `.all` のまま。誤キャプションは `captionModelVersion` を 2→3 に上げて起動時に全消去＆付け直し。確認用に `VLMRuntime.caption` へ生成ID＋テキストの Diagnostics ログを追加。
- 関連: `MobileCLIPKit/CoreMLModelSupport.makeConfiguration(avoidNeuralEngine:)`・`VLMRuntime.loadAll`（VLM 用 config）・`AutoAlbumEngine.captionModelVersion`(2→3)・`scripts/convert_florence.py`。[[ADR-32]]。
- 残課題: CPU+GPU でも駄目なら CPU_ONLY（確実だが低速）へ。実機での速度・正しさは要再計測（Mac 値は ~0.4秒/枚だが ANE 前提だった）。座標bin後処理を使う OCR タスク化は今後。

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
