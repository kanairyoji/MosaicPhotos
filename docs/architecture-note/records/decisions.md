# 設計判断の記録（ADR）— マスター

> このファイルが**設計判断の正本（マスター）**です。HTML（`docs/architecture-note/design-decisions/adr.html`）は、ここから必要なものを選んで記載した派生物であり、全件を転記するとは限りません。
>
> **運用ルール**
> - 設計上の判断をしたら、必ずこのファイルに 1 項追記する（網羅）。
> - HTML へ載せるかは別途指示で決める（取捨選択）。
> - フォーマット: `## ADR-N タイトル` ＋ **文脈 / 決定 / 結果（トレードオフ）**。番号は連番。
> - 撤回・変更時は項を消さず「状態: 置換（→ ADR-M）」のように追記して経緯を残す。

## テンプレート

```
## ADR-N タイトル
- 状態: 採用 / 置換(→ADR-M) / 廃止
- 文脈: なぜ判断が必要か。
- 決定: 何を選んだか。
- 結果: 得たもの／トレードオフ。
- 関連: コミット・ファイル・関連 ADR/事例。
```

---

## ADR-1 検索を語彙ゼロのオープン語彙 CLIP に一本化
- 状態: 採用
- 文脈: 固定タグ方式は語彙外検索に弱く、辞書の保守も負担。
- 決定: 固定語彙・OCR を捨て、CLIP のオープン語彙＋構造化条件＋字句の RRF 融合にする。
- 結果: 自由なクエリに強い。代わりに全写真の画像埋め込み（背景処理）が必要。表示タグだけは別途ゼロショットで出す。
- 関連: `AutoAlbumCore/AIAlbum/`、`MobileCLIPKit/`。

## ADR-2 写真ソースを共通プロトコルに統一
- 状態: 採用
- 文脈: 端末・Dropbox・統合で同じ閲覧体験を出したい。
- 決定: `PhotoStore` / `PhotoItem` / `PhotoLoadState` に揃え、共通ビューを共有。
- 結果: 新ソースを足しても表示側は不変。各ソース固有の init パラメータは維持。
- 関連: `PhotoSourceKit/Interface/`。

## ADR-3 ロジック層 / UI 層の分離（Core/UI）
- 状態: 採用
- 文脈: 副作用（PhotosKit/URLSession/SwiftData）を UI から切り離してテストしたい。
- 決定: `*Core`（SwiftUI 非依存）と `*Kit`（UI・`@_exported import`）に分割。
- 結果: 純ロジックを macOS で高速テスト。import は 1 つで済む。パッケージ数は増える。

## ADR-4 グリッドを UICollectionView に置換
- 状態: 採用
- 文脈: 6 万件で `LazyVGrid` + `scrollTo` のスクラバーが不安定。
- 決定: `UIViewRepresentable` で UICollectionView（diffable・プリフェッチ・contentOffset スクラバー）を採用。
- 結果: 大ジャンプが安定。UIKit のボイラープレートが増える。
- 関連: コミット 9897653、事例「スクラバー不具合」。

## ADR-5 単一 fullScreenCover + enum で遷移
- 状態: 採用
- 文脈: 複数の `.fullScreenCover(item:)` 併用で提示競合し、別アルバムの中身が出る不具合。
- 決定: 遷移先を単一の `HomeDestination` enum にまとめ、`.fullScreenCover` は 1 つに。`.sheet` も同様に統合。
- 結果: 競合解消。分岐は `switch` に集約。
- 関連: `MosaicPhotos/HomeView.swift`、事例「アルバムが無関係な写真になる」。

## ADR-6 CLIP 埋め込みを別テーブル + Float16
- 状態: 採用
- 文脈: 埋め込みを `PhotoEnrichment` に inline 格納していたため、全件 fetch のたびに 138MB 級 blob を展開し、写真の多い実機で起動クラッシュ。
- 決定: 埋め込みを `PhotoEmbedding` 別テーブルへ分離し、Float16 で保存。メタデータ fetch は blob に触れない。
- 結果: 常駐が「ページ 1 枚分」に。スキーマ再構築（`AutoAlbumV10`）が必要。
- 関連: コミット f84529c、事例「メモリ枯渇」。

## ADR-7 ModelContainer を自己修復で構築
- 状態: 採用
- 文脈: SwiftData は破損・不整合で起動時 trap し、実機で原因不明クラッシュ。
- 決定: `makeResilientContainer` で「削除→再試行→インメモリ」とフォールバック。
- 結果: 起動を止めない。最悪データは失うが回復する。
- 関連: コミット 7e53db3。

## ADR-8 起動の重いストア構築を非同期化
- 状態: 採用
- 文脈: `HomeView.init` が同期で `ModelContainer` を作り、最初の描画をブロック。
- 決定: `RootView` が `HomeStores.build()` で非同期構築し、1 秒超でローディング表示。
- 結果: 体感起動が改善。
- 関連: コミット 8bc97dd、事例「起動の高速化」。

## ADR-12 AI アルバム検索を合成可能な QuerySpec（OR/NOT/多ファセット）へ拡張
- 状態: 採用（フラットな `AIAlbumQuery` の AND 専用を一般化。`AIAlbumQuery` は後方互換で残す）
- 文脈: 「ここ2年の子供」「京都か奈良の家族のお気に入り、スクショ除く」等、アプリが持つ多様な情報（日付/場所/人物/人数/向き/位置/ソース/内容）への複雑条件・OR・NOT を柔軟に組みたい。
- 決定: DNF（節の OR・節内 AND・各条件 NOT 可）の `QuerySpec`/`QueryClause`/`Condition` を新設。ハード条件（日付/場所/人物/人数/ソース/お気に入り/スクショ/向き/位置）は `QueryEvaluator` で評価、内容語(content)は CLIP でソフト採点（`AIAlbumSearcher.search(baseLite:spec:)`）。相対日付は `RelativeDateParser`（日英）で FM 非対応端末でも解釈。Foundation Models は `GeneratedSpec`（Generable・clauses=OR）で出力、RuleBased はフラット解釈を単一節へ橋渡し。`AIAlbumService` は `interpretSpec` 経由に配線。
- 結果: AI アルバムが複雑条件・OR・相対日付に対応。除外内容(not(content))の減点と、日付/場所の多ソース解決（旅行アルバム由来）は次段（P2/後続）。純ロジック中心で `swift test` 担保。
- 関連: `AIAlbum/QuerySpec.swift` / `QueryEvaluator.swift` / `RelativeDateParser.swift` / `AIAlbumSearch.swift` / `FoundationModelsQueryUnderstanding.swift` / `AIAlbumService.swift`。

## ADR-11 CLIP 画像エンコーダを fp16 のみにする（実機 ANE 優先）
- 状態: 採用（旧「fp32（シミュレータ NaN 回避）」を置換）
- 文脈: 実機ログで画像埋め込みが 1 枚 0.5〜1.3 秒と遅い。原因は画像エンコーダを `compute_precision=FLOAT32` で変換していたため、Neural Engine(ANE) に載らず GPU/CPU フォールバックしていたこと。元の fp32 はシミュレータの NaN 回避が目的だったが、シミュレータ最適化は本末転倒。
- 決定: `convert_mobileclip.py` の画像エンコーダ変換を `FLOAT16` にする（実機 ANE 対応＝高速化）。fp16 はシミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落として安全に無効化する。`ImageRecognitionTests` の画像タワー依存テストはシミュレータでスキップし実機検証に寄せる。
- 結果: 実機の埋め込みが ANE 実行で高速化する見込み（要・実機実測）。シミュレータでは画像 CLIP が無効化され得る（テキスト系は不変）。モデルは `build_mobileclip.sh` の再実行で再生成が必要。
- 関連: `scripts/convert_mobileclip.py`、`MobileCLIPRuntime`（simulator `.cpuOnly` / 実機 `.all`）、事例「CLIP 埋め込みが遅い」。

## ADR-10 GitHub を CI・公開・リリースに活用
- 状態: 採用
- 文脈: 個人開発でも回帰検知・設計資料の公開・タグ運用の自動化が欲しい。秘密の誤コミットも機械的に防ぎたい。
- 決定: GitHub Actions で CI（`scripts/test.sh fast` を gate、iOS sim は best-effort）/ Pages で `docs/architecture-note` を公開 / タグ push で Release 自動生成。リポジトリ設定で Secret scanning + Push Protection、CodeQL（default setup）を有効化。
- 結果: push ごとに回帰検知、設計資料が公開URL化、リリースノート自動化、秘密混入の自動ブロック。ワークフロー push にはトークンの `workflow` スコープが必要。iOS 26 シミュレータはランナー事情に依存するため iOS テストは非ブロッキング。
- 関連: `.github/workflows/ci.yml` / `pages.yml` / `release.yml`。

## ADR-9 Diagnostics で端末上ログ
- 状態: 採用
- 文脈: 実機で Mac/Console なしに不具合を追えない。
- 決定: 未捕捉例外・メモリ圧迫・各ログを `Caches/diagnostics.log` に残し、Developer Options で閲覧/共有。
- 結果: 実機の原因追跡が可能に。`fatalError`/SwiftData trap は対象外（標準クラッシュログ側）。
- 関連: コミット cfc8223 前後、`MosaicSupport/Diagnostics.swift`。
