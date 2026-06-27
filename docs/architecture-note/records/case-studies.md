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

## フォルダ名アルバムが動かない（正規表現を写真ごとに再コンパイル）
- 症状: フォルダ名アルバムの日付抽出を入れた後、生成が事実上停止し「動かない」。
- 原因: `FolderDateParser`（約10パターン）と `PathAlbumNamer`（ルール）が **写真1枚ごとに `NSRegularExpression` を毎回コンパイル**。Dropbox 67,639 枚 ×（10＋ルール数）で数十万回のコンパイルになり生成が終わらない。
- 対処: (1) 両者の正規表現を `NSCache` で**コンパイル結果をキャッシュ**（スレッドセーフ）。(2) `PathAlbumStrategy` で**日付解析をフォルダ単位にメモ化**（写真ごとに再解析しない）。これで解析回数は「フォルダ数」程度に激減。
- 関連: `FolderDateParser.swift` / `PathAlbumNamer.swift` / `PathAlbumStrategy.swift`。ADR-13。
- 学び: 大量データ（数万件）を回す純ロジックでは、`NSRegularExpression` の**コンパイルをループ内で繰り返さない**（事前コンパイル/キャッシュ）。入力単位（フォルダ等）でのメモ化も併用する。

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
