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

## 月グループで疎な月が密に表示されない（coalesce しきい値が perf 最適化で固定4に劣化）
- 症状: 写真の少ない月が多いと、月グループ表示で「ヘッダー＋半端な1行」が並んで疎になる。特定ビュー限定に見えるが、実際は全ソース/アルバムビューが共通の `PhotoGridView`→`PhotoCollectionView` を使うため挙動は全ビュー共通。
- 原因: 当初（ea80c1ab）は coalesce しきい値＝**実列数**（monthGroup は 15）で、1行に満たない連続月を範囲セクションに束ねていた。だが perf 最適化（29291a25「列変更＝ピンチで再構築しない」）でスナップショットのシグネチャから列数を外した副作用として coalesce を**固定値 4** に変更してしまい、monthGroup（15列）で 4〜14枚の月が束ねられず疎のまま残った。
- 対処: coalesce しきい値を実列数へ戻す（`grouping==.month ? max(1, columns) : 0`）。grouping==.month の列数はズーム段階で固定（dense/year では coalesce=0 で不変）なので、シグネチャに `c<coalesce>` を加えてもピンチ（dense/year の列変更）では再構築が起きず、perf 配慮（68k で再構築を繰り返さない）は維持。`applySnapshot(coalesce:)` で受け渡し。表示は全ビュー共通＝1か所の修正で全体に適用される。
- 関連: `PhotoSourceKit/Views/PhotoCollectionView.swift`（signature/applySnapshot）、`Support/PhotoGridGrouping.swift`（coalesceBelow）。
- 残課題: しきい値は「列数未満は束ねる」方針。月の見え方を細かく調整したい場合は設定化の余地。

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
