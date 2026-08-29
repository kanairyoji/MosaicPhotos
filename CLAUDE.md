# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**MosaicPhotos** は iOS (iPhone) 向けの写真ビューワーアプリ。端末内の写真と Dropbox 上の写真を、ソース別（All / Photos / Cloud）・端末アルバム別・場所（市区町村）別に閲覧できる。外部 SDK・ライブラリは不使用（コードはすべて標準フレームワーク）。AI はオープンソースの学習済みモデル（OpenCLIP / facenet）を同梱し、OS 内蔵の Core ML・Vision・Foundation Models で実行する。

加えて **オンデバイス AI** を持つ：自然文（任意言語）の **AI アルバム / 意味検索**を「タグ台帳＋LLM審査」の多層構成（ADR-23/24）で実現する。索引は夜間バッチ（電源＋アイドル/ロック中 BGTask）で **Vision シーンタグ（約1,300クラス・精度校正済み）→ CLIP 埋め込み（OpenCLIP ViT-B-32・INT8量子化・Core ML・ADR-31）** の順に付与（タグ/埋め込みとも全写真・台帳に永続化。※ VLM キャプションは検索寄与ゼロの実測により廃止＝ADR-108）。検索は「決定的ハード条件（日付=RelativeDateParser・場所/人物接地・レキシコン）→ タグ一致＋CLIP 対比＋字句の RRF 融合 → 証拠ゲート → FM LLM 審査（多数決）」。解釈（LLM）はアルバム作成時に 1 回だけ実行して永続化する。通信なし・API キー不要。


### 技術スタック

| 項目 | 内容 |
|---|---|
| 言語 | Swift |
| UI | SwiftUI |
| 状態管理 | Swift Observation (`@Observable`) |
| 端末写真 | PhotosKit (`PHPhotoLibrary`, `PHImageManager`) |
| Dropbox OAuth | `AuthenticationServices`（`ASWebAuthenticationSession`、PKCE） |
| トークン保存 | `Security`（Keychain Services） |
| Dropbox API | `URLSession` async/await（外部 SDK 不使用） |
| Dropbox キャッシュ | SwiftData（メタデータ）+ `ImageCacheKit`（バイナリ。`DropboxCacheStore`（actor）が `MemoryImageCache`/`DiskImageStore` を利用） |
| オンデバイス AI | 多層構成（ADR-24）: **Vision 画像分類**（OS 内蔵・約1,300クラス・`hasMinimumRecall(forPrecision:)` の校正済み足切り）＋ **OpenCLIP ViT-B-32（DataComp・MIT・INT8量子化＝容量半減/精度ほぼ不変・ADR-31）**（Core ML・画像/テキスト埋め込み。ファイル名 `MobileCLIP*` は互換のため据え置き）（※ VLM キャプション＝SmolVLM は廃止。検索寄与ゼロの実測＝台帳 S13・ADR-108）。クエリ解釈・翻訳・候補審査は Apple Foundation Models（`FoundationModels`）で、解釈は**作成時 1 回・永続化**（ADR-23）＋防御的サニタイズ＋決定的レキシコン。ロジックは `AutoAlbumCore`、各ランタイム/seam 実装は `MobileCLIPKit` に集約 |
| 端末診断 | `MosaicSupport` の `Diagnostics`：未捕捉例外（`NSSetUncaughtExceptionHandler`）・メモリ圧迫（`DispatchSource`）・各ログを `Caches/diagnostics.log` に追記し、Developer Options で閲覧/共有（実機で Mac/Console なしに原因追跡） |
| 最小 iOS | iOS 26.0（アプリターゲットの `IPHONEOS_DEPLOYMENT_TARGET`。各 SPM パッケージは `.iOS(.v17)` 宣言＋`@available` ゲートで macOS テストも維持） |
| パッケージ管理 | Swift Package Manager（ローカルパッケージ 13 個。基盤: `MosaicSupport` / `PhotoSourceKit` / `ImageCacheKit` / **`PerceptionCore`**（ClipMath・PhotoRef・BackgroundTrickle・AnalysisActivity＝CLIP と顔の共通下層）、ローカル写真: `LocalPhotoCore`(ロジック) / `LocalPhotoKit`(UI)、Dropbox: `DropboxCore`(ロジック) / `DropboxKit`(UI)、`BackupKit`、写真機能統合: `PhotosFeatureKit`、**顔認識/ピープル: `FaceCore`**（依存 PerceptionCore・顔クラスタ一式）、自動アルバム/AI: `AutoAlbumCore`（`@_exported import` で PerceptionCore/FaceCore を再エクスポート＝consumer は import AutoAlbumCore のまま）、CLIP ランタイム/AI seam 実装: `MobileCLIPKit`） |

---

## Build & Test Commands

```bash
# ビルド
xcodebuild -project MosaicPhotos.xcodeproj -scheme MosaicPhotos -sdk iphonesimulator build

# 全テストを一括実行（推奨）。パッケージのテスト（macOS swift test + iOS シミュレータ）を回す。
#   fast = macOS swift test のみ / ios = シミュレータのみ / all = 両方
scripts/test.sh all

# 個別パッケージ（純ロジックは macOS で高速実行）
cd Packages/PhotoSourceKit && swift test

# UIKit/SwiftData/Photos 依存のテストは iOS シミュレータ必須
cd Packages/DropboxCore && xcodebuild test -scheme DropboxCore \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
cd Packages/PhotosFeatureKit && xcodebuild test -scheme PhotosFeatureKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# UI テスト（アプリスキーム）
xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MosaicPhotosUITests
```

> テストは2系統に分かれる: Foundation のみの純ロジックは macOS `swift test` で高速実行
> （`scripts/test.sh` の FAST_PACKAGES）、UIKit / SwiftData / Photos に依存するものは
> `#if canImport(UIKit)` で囲い iOS シミュレータの `xcodebuild test` で実行する（IOS_PACKAGES =
> `DropboxCore` / `PhotosFeatureKit`）。`scripts/test.sh all` が両者を一括で走らせる。
>
> - **`AutoAlbumCore`** は SwiftData/Foundation のみの純ロジックなので macOS `swift test`（FAST）で回る
>   （`ClipMath` / `AIAlbumSearcher` / `LexicalSearch` / `BackgroundProcessing` など）。
> - **アプリターゲットの単体テスト（`MosaicPhotosTests`）= `ImageRecognitionTests`**：CLIP の有限性
>   （fp16 NaN 回帰）・画像/テキスト識別・オープン語彙の自然文一致・表示ラベラ・翻訳素通しを検証する。
>   絵文字をレンダリングした画像を使い、**MobileCLIP モデル未同梱の環境では `XCTSkipUnless` でスキップ**。
>   実行は `xcodebuild test -only-testing:MosaicPhotosTests/ImageRecognitionTests`。
> - **既知の落とし穴**: ローカルパッケージ（例 `DropboxCore`）に*新規ファイル*を追加すると、
>   それに依存する別パッケージの `.build` が stale になり `swift test` が「型が見つからない」で
>   落ちることがある。`rm -rf Packages/*/.build` してから再実行で解消する。

---

## Architecture

### どこに何があるか

新しいコードの置き場所を決めるための地図。**ファイル単位の詳細は各パッケージ直下の
`CLAUDE.md`** にあり、そのディレクトリを触ったときに自動で読み込まれる
（root に全部書くと、毎セッション全パッケージぶんを読むことになるため分けた）。

| 層 | パッケージ | 持ちもの |
|---|---|---|
| 基盤 | `MosaicSupport` | ログ・診断・PerfTrace・メモリ/熱・背景処理のゲート・SwiftData 自己修復 |
| 基盤 | `PhotoSourceKit` | 写真ソースの共通インターフェイスと汎用ビュー（グリッド/フル画面/場所） |
| 基盤 | `ImageCacheKit` | メモリ/ディスクの画像キャッシュ・プリミティブ |
| 基盤 | `PerceptionCore` | ClipMath・PhotoRef・ANE ゲート・背景トリクル（CLIP と顔の共通下層） |
| 端末写真 | `LocalPhotoCore` / `LocalPhotoKit` | ロジック / UI |
| Dropbox | `DropboxCore` / `DropboxKit` | ロジック / UI |
| Dropbox | `BackupKit` | 端末写真 → Dropbox のバックアップ・オフロード・家族共有 |
| 統合 | `PhotosFeatureKit` | Local + Dropbox の統合（`MergedPhotoStore`）・場所グルーピング |
| AI | `AutoAlbumCore` | 自動アルバム・AI 検索・タグ台帳（SwiftUI 非依存） |
| AI | `FaceCore` | 顔検出・クラスタリング・ピープル |
| AI | `MobileCLIPKit` | CLIP/顔モデルのランタイムと、上記 seam のアプリ側実装 |
| アプリ | `MosaicPhotos/` | 合成のみ（`HomeView`・Composition Root・設定画面・BGTask） |

**ファイルを探すときは `grep` / `find` を使う**（一覧を暗記しない）。
アーキテクチャの背景は `docs/architecture-note/` にある。

> **規約を書き足すときの置き場所**
> - **横断的**（レイヤー分離・並行性・記録・性能原則・i18n・テスト）→ この root ファイル。
>   新しいコードを**どこに置くか決める時点**で要る知識は、そのディレクトリを触る前なので
>   root に無いと効かない。
> - **そのパッケージの中だけで完結する**（ファイルの役割・内部の作り）→ 各パッケージの
>   `CLAUDE.md`。触ったときに読まれる。

### コンポーネント関係

```
MosaicPhotosApp
  └── HomeView  (@State dropboxStore / mergedStore / backupEngine / albumScanner / placeScanner)
        ├── [All Photos] PhotoSourceContentView(store: MergedPhotoStore)   ← import PhotosFeatureKit（Local + Dropbox 統合）
        ├── [Photos]     LocalPhotoContentView      ← import LocalPhotoKit（LocalPhotoStore）
        ├── [Cloud]      DropboxContentView         ← import DropboxKit（DropboxPhotoStore）
        ├── [Albums]     端末アルバム / Time&Place 旅行 / フォルダ名 / AI アルバム ← AutoAlbumEngine
        ├── [People]     ピープル（顔クラスタ）← PeopleEngine（Vision 顔検出＋同梱顔モデルで埋め込み→逐次クラスタリング・端末写真1024px＋クラウドはキャッシュ済みサムネ。多段ゲート／アライメント／2階層束ね＝下記）。Time&Place 直下・顔モデル未同梱なら非表示
        ├── [Places]     PlacePhotosView            ← PhotosFeatureKit の PlaceScanner / MergedPhotoStore（場所フィルタ）
        └── [Settings sheet] SettingsView（Settings.app 風グルーピング List → 各画面へ NavigationLink）
              ├── On-Device Photos  LocalPhotoSettingsView   ← import LocalPhotoKit
              ├── Dropbox           DropboxHubView           ← 接続(DropboxSettingsView)＋Backup＋フォルダアルバムのハブ
              ├── Storage           StorageSettingsView      ← キャッシュ説明・上限
              ├── Places            PlacesSettingsView
              ├── Albums            AutoAlbumSettingsView    ← AI/旅行/フォルダ生成＋画像認識（再解析・背景処理速度段階）
              └── Developer Options DeveloperSettingsView    ← 各 Debug セクション＋診断（メモリ/CLIP 同梱/ログビューア）

各ソースビューは PhotoSourceKit の PhotoSourceContentView → PhotoCollectionView（UICollectionView・
GridThumbnailCell / GridSectionHeaderView / GridScrubberView）→ PhotoPageView（FullPhotoView / PhotoInfoPanel）を共有する。
PhotoSourceContentView は全状態（grid / 未接続 / 空 / 失敗）の最下部に Home / Settings バーを表示する。
フル画像（PhotoPageView）は環境注入された `photoInsight` クロージャ（→ `AutoAlbumEngine.insight`）で
表示タグ・人物・解析状態を取得して情報パネルに出す（PhotoSourceKit は AutoAlbumCore に依存しない）。
```

### Dropbox 認証フロー（PKCE）

`ASWebAuthenticationSession` を使った標準 OAuth 2.0 + PKCE フロー。カスタム URL スキーム `MosaicPhotos://oauth/dropbox` でコールバックを受け取る。

---

## Key Conventions

- **Swift Observation**: `@Observable` を使用。`ObservableObject`/`Combine` は使わない（iOS 26 SDK では `import Combine` が明示的に必要なため）
- **MainActor isolation**: ビルド設定 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` により全型がデフォルト `@MainActor`。`PHImageManager` 等のコールバックはバックグラウンドスレッドで来るため `Task { @MainActor in ... }` でメインに戻す
- **ファイル自動認識**: Xcode 16 の `PBXFileSystemSynchronizedRootGroup` を使用。`MosaicPhotos/`（および `MosaicPhotosTests/` / `MosaicPhotosUITests/`）に追加した `.swift` ファイルは `project.pbxproj` を変更せず自動コンパイルされる。**ただし新しいローカル SPM パッケージをアプリが参照する場合は別**で、`project.pbxproj` に `XCLocalSwiftPackageReference` / `XCSwiftPackageProductDependency` / Frameworks ビルドフェーズの配線が必要（既存パッケージに transitive 依存する新パッケージ — 例 `LocalPhotoCore` — はアプリが直接参照しないため pbxproj 変更不要）
- **NSPhotoLibraryUsageDescription**: `project.pbxproj` の `INFOPLIST_KEY_NSPhotoLibraryUsageDescription`（Debug・Release 両方）で設定済み
- **ロジック層 / UI 層の分離（Core/UI 構成）**: 端末写真と Dropbox はそれぞれロジック層（`LocalPhotoCore` / `DropboxCore`・SwiftUI 非依存）と UI 層（`LocalPhotoKit` / `DropboxKit`・前者に依存）の 2 パッケージに分離する。UI パッケージはロジックパッケージを `@_exported import` するため、ホストアプリは `import LocalPhotoKit` / `import DropboxKit` だけで両層の公開型を参照できる（※ UI パッケージ内の各ファイルは横断利用するロジック型を明示 `import` する。@_exported は外部 consumer 向け）。`DropboxCore` の依存は `Foundation` / `AuthenticationServices` / `CryptoKit` / `Security` / `SwiftData` / `UIKit` / `ImageCacheKit` / `MosaicSupport` のみ。ロジック層はメインアプリを一切 import しない
- **写真機能の統合は PhotosFeatureKit に集約**: ローカルと Dropbox を統合する `MergedPhotoStore` / `MergedPhotoItem`、場所グルーピングの `PlaceScanner` は `PhotosFeatureKit`（`DropboxKit` / `LocalPhotoKit` / `PhotoSourceKit` に依存）に置く。アプリターゲットは HomeView と組み立てに専念し、これらのロジックを持たない
- **AI/自動アルバムは AutoAlbumCore に集約（SwiftUI 非依存）**: 旅行/フォルダ/AI アルバム生成・知覚・検索は `AutoAlbumCore`。`@Model` は `@ModelActor`（`AutoAlbumStore`）の外へ漏らさず Sendable 値（`EnrichedPhoto` 等）に変換して返す。ファサードは `@MainActor @Observable` の `AutoAlbumEngine`。スキーマ変更時は `ModelConfiguration` 名（現行 `"AutoAlbumV10"`）を採番して旧ストアを破棄→再構築する
- **@ModelActor は専用シリアルキューで走らせる（ADR-121）**: SwiftData の既定 executor は**ジョブを「呼び出し元のスレッド」で実行する**。MainActor から `await store.…` と書くと fetch は**メインスレッドで走る**（`await` があるので見た目はオフメイン＝レビューでも気づけない。実測 10.9 秒の前面ハング）。**「init したスレッドに束縛される」は誤り**で、オフメイン生成では防げない。新しい `@ModelActor` を足したら必ず `nonisolated var unownedExecutor` を `ModelStoreExecutor.serialQueue(label:)` に差し替え、`ModelActorExecutorTests` と同型の回帰テスト（MainActor から呼んで `Thread.isMainThread == false`）を 1 本足す。キューに QoS は付けない（enqueue 側の優先度を引き継がせる）
- **ModelContainer は自己修復で構築**: SwiftData の `ModelContainer` 初期化は、ストア破損・スキーマ不整合のとき起動時に trap して実機で原因不明のクラッシュになりやすい。`AutoAlbumStore` / `DropboxCacheStore` / `BackupEngine` は `makeResilientContainer(...)` で「失敗→ストアファイル（.store/-wal/-shm）削除して再試行→なお失敗ならインメモリ」とフォールバックし、起動を止めない（失敗は診断ログへ）
- **CLIP 埋め込みは別テーブル＋Float16＋ページング**: 埋め込みを `PhotoEnrichment` に inline 格納すると、SwiftData は全件 fetch（生成・重複排除・戦略・prune）のたびに巨大 blob も展開し、67k×2KB≈138MB を確保 → **写真枚数に比例した実機起動クラッシュ**になっていた。そのため埋め込みは **`PhotoEmbedding` 別テーブルに Float16（約1KB/枚）** で分離し、メタデータ fetch が blob に一切触れないようにする。意味検索は `enrichmentVectorPage(offset:limit:)`（`PhotoEmbedding` を refKey 昇順でページング・fp32 へ復元して返す）を `AIAlbumSearcher.search(baseLite:...loadPage:)` にストリームする。`allEnrichedPhotosLite()` はメタのみ（埋め込みなし）。純関数版 `search(_ all:)` と選定ロジックは一致させる。大量 upsert は `writeChunk` 件ごとに使い捨て `ModelContext` で save→解放して常駐を有界に保つ
- **AI アルバム検索は「タグ台帳＋LLM審査」の多層構成（ADR-23/24）**: 解釈（LLM・`FoundationModelsQueryUnderstanding`）は**作成/編集時に 1 回だけ**実行し `AIAlbumInterpretationStore`（JSONFileStore・版管理）へ永続化する（起動時・写真追加時に LLM は走らない）。小型 LLM の構造化出力は信用せず、`QuerySpecSanitizer`（プレースホルダ除去・カタログ丸写し検出・include/exclude 衝突解消）＋**決定的レイヤー**（日付=`RelativeDateParser` が唯一の出典・place/people はカタログ/原文接地・`JapaneseVisualLexicon` で頻出視覚語と人物否定を抽出）で必ず接地する。検索は「ハード条件（`QueryEvaluator`）→ **Vision シーンタグ一致（離散・閾値レス）**＋ CLIP 対比（除外は肯定/否定ベクトルの相対判定のみ・絶対閾値なし）＋字句（`LexicalSearch`）の RRF 融合（`HybridFusion`）→ **証拠ゲート**（除外つきはタグ/顔実測/人数実測の証拠必須）→ **FM LLM 審査**（`AlbumVerifier`・keep/drop/unsure・unsure は最大2回再判定の多数決）→ 空振り時はプローブ拡張で 1 回だけ再検索」。再評価は増分（新規埋め込み分のみ採点しスコアプールへマージ）＋ドリフト検知のフル再評価。旧フラット `AIAlbumQuery` は解釈フォールバック（RuleBased/FM flat）用に残る（検索 API は撤去済み）。**検索の精度はクエリ集ハーネスのデータセット計測で決める**（ADR-104・`docs/architecture-note/records/search-quality.md`＝台帳・COCO/Caltech・`SearchEvalTests`/`SearchEvalCaltechTests`。解釈・照合・接地・証拠まわりを変えたら両ハーネスを回して差分を台帳へ記す。体感・個別事例では決めない）
- **知覚 seam はプロトコル＋`MobileCLIPKit` 実装**: `PhotoPerceptionProvider`(refKey→CLIP 埋め込み・ローカル/クラウド両対応) / `TextEmbedder` / `QueryTranslator`(Foundation Models) / `LabelProvider`(表示タグ) は `AutoAlbumCore` のプロトコルで、実体は `MobileCLIPKit`（`AIPerceptionAdapters` / `AILanguageAdapters` / `CLIPDisplayLabeler`）が `MobileCLIPRuntime`・`FoundationModels` で実装する。アプリの `AutoAlbumAdapters`（Composition Root）が `AutoAlbumEngine` の seam に注入する。`PhotoSourceKit` は `AutoAlbumCore` に依存せず、フル画像の付加情報は `photoInsight` 環境クロージャ経由で受け取る（レイヤー分離）
- **表示タグ＝検索と同一の台帳**: フル画像のタグ欄（常時表示）は **Vision シーンタグ（`TagStore`・検索の一次ランキングと同一ソース）を第一**に、`CLIPDisplayLabeler`（約300語ゼロショット）で補完する。タグは **TagsV1 別コンテナ**（`PhotoTagRecord`）で、夜間バッチ（`TagTagger`）が Vision タグ → CLIP 埋め込みの順に付与する。※ VLM キャプション（AI description）は廃止（ADR-108・`PhotoTagRecord.caption` フィールドはスキーマ互換のため残置）
- **規模で壊れるコードを、規模のテストで止める（ADR-119）**: 実機で繰り返した性能バグ
  （18 秒・27.8 秒のハング、1GB でのクラッシュ）は**すべて同じ形**だった——
  **「1 回ぶんに見える呼び出し」が、実はライブラリ規模に比例していた**。
  `items.first { $0.id == x }`（全走査＋毎回 String 生成）、クラスタごとの `fetch`（1,316 回）、
  対ごとに全記録を舐める照合（52 万対 × 記録数）。どれも**書いた時点では正しく速く**、
  ライブラリが育って初めて表に出る。「動くこと」のテストでは永久に捕まらない。
  - **一覧・辞書・記録の全件を触る処理を書いたら、規模テストを 1 本足す**。
    検証するのは**時間ではなく回数**（fetch 回数・id の読み出し回数）。時間は CI で揺れるが
    回数は決定的。`PerfTrace.takeCounts()` で読める（`FaceStore.countedFetchOptional` が実例）。
  - 形は「**規模を 4 倍にして、回数が比例して増えないこと**」。例:
    `Packages/FaceCore/Tests/FaceCoreTests/ScaleRegressionTests.swift`。
  - ⚠️ **fixture が本当にその状態になっているかを assert する**。2 回踏んだ——(1) 埋め込みが
    似すぎて全員が 1 クラスタに合流し、N を増やしてもクラスタが増えなかった。(2) 前提の行
    （`PhotoEnrichment`）を作っておらず、対象処理が**常に空を返す**のに `count <= n` と
    `allSatisfy` で通っていた。**空でも通る assert を書かない**。
  - ⚠️ **回数を数える**。取得**結果の件数**を検証しても、1 件ずつ引く実装に戻して通ってしまう
    （レビュー指摘）。件数は「取りこぼしていないこと」の確認用で、規模比例の検出にはならない。
  - ⚠️ 打ち切り上限を入れたなら、テストの規模は**その上限を跨ぐ**こと。下回る範囲だけで測ると
    上限が効いているのか元から少ないのか区別できない。
- **性能設計の既定原則（重い処理を書く/直すときは必ず通す）**: 遅さの相談を受けたら、**まず 1 単位あたりの内訳を実測**（I/O・通信・推論・DB のどれが支配的か）してから手を入れる。そのうえで以下を**言われる前に**適用する。
  1. **I/O と計算は重ねる**（最重要）。通信・ディスク読み・デコードと、推論・計算が交互に来る逐次ループは、待ち時間がまるごと無駄になる。**次の単位の取得を、現在の単位の処理中に始める**（1 バッチ先読み）。ANE ゲートは推論だけを直列化し通信は縛らないので、通信は推論の裏に完全に隠せる（ADR-83 の実例＝クラウド解析の 85〜90% が DL 待ちだった）。
  2. **往復はまとめる**。1 件ずつの API 呼び出しはバッチ API の利点を消す（Dropbox サムネは 25 枚/リクエスト・並列）。ループの中で単発リクエストを見たら疑う。
  3. **無いものを繰り返し探さない**（negative caching）。存在しないリソースの問い合わせも往復コスト（ADR-82 の実例＝毎起動 409 × 4 回・各 3 秒）。ただし**無効化経路を必ずセットで**用意する。
  4. **巨大コレクションを MainActor に通さない**。数万件の fetch・map・sort は `Task.detached` で行い、メインへは完成値（件数・数百件の結果）だけ返す（ADR-71/82）。
  5. **計測が体感を表しているか確かめる**。背面の停止・プロセス中断は体感と無関係（ADR-82）。文脈の違う値を同じ数値に混ぜない。
- **背景 CLIP 埋め込みのスロットリング**: `PhotoTagger.embedUnprocessed` は小バッチ＋バッチ間スリープ＋`.background` QoS で trickle 実行する。重さは `BackgroundProcessing.presets`（段階）で設定可能（`AutoAlbumSettingsView`・キーは `AutoAlbumSettingsKeys.backgroundProcessingLevel`）。各段は名称＋パラメータ（件数/休止秒）を UI に提示する。**停止判定は 1 枚単位**（`perceive` をバッチ一括でなく 1 枚ずつ呼び、各推論の前に `shouldPause` を確認）で、操作・遷移が来たら即譲れるようにする（8枚一括だとその間 CPU/ANE を握って画面遷移が飢餓する）。`shouldPause` でユーザー操作中（スクラブ）と **メモリ圧迫中（`MosaicSupport.MemoryPressureMonitor.isUnderPressure`）** と **クラウドのサムネ取得中（`BackgroundActivityMonitor.cloudThumbnailBusy`＝Dropbox バッチャのドレイン中）** と **フル画像取得中（`fullImageBusy`＝`DropboxActivityMonitor.beginFullImage` が橋渡し）** と **写真ビュー表示中（`isViewingPhoto`＝タップ直後の遷移含む。`PhotoPageView`/グリッドが報告）** は処理を譲る（メモリ圧迫は `Diagnostics` の warning/critical でフラグ＋自動解除）。**シミュレータでは背景埋め込みを実行しない**（CLIP が `.cpuOnly` で 1 枚数秒〜十数秒かかり遷移を飢餓させ検証の妨げになるため。`#if targetEnvironment(simulator)` で早期 return・実機=ANE の挙動は不変）
- **メモリ圧迫対応は `MemoryPressureMonitor` に集約**: `Diagnostics` の `DispatchSource` 圧迫イベントは `MemoryPressureMonitor.handle(level:)` に流すだけ。中枢が (1) 圧迫フラグ設定（自動解除）、(2) **登録された解放ハンドラ**の呼び出し、(3) 診断ログ追記（レベル/footprint/端末RAM）、(4) Developer Options 用の履歴/回数蓄積を行う。`MemoryImageCache` は `register(_:)` した解放ハンドラで **warning=上限半減（LRU 縮小）／critical=即時全消去** する（`ImageCacheKit` → `MosaicSupport` 依存）。履歴は `MemoryDebugSection` に表示（ADR-20）
- **CLIP モデルの扱い**: 同梱モデルは **OpenCLIP ViT-B-32/datacomp_xl（MIT）**。Core ML モデルと語彙は `MosaicPhotos/MobileCLIP/` に置き **`.gitignore` 対象**（サイズ）。`scripts/build_mobileclip.sh`（内部で `scripts/convert_clip.py`・open_clip→Core ML）で生成する。ファイル名は `MobileCLIP*`／config 名 `mobileclip_config.json` を互換のため据え置き（中身は OpenCLIP）。⚠️ 変換は**画像エンコーダを `compute_precision=FLOAT16`**（実機 ANE は fp16 前提）。**CLIP の mean/std 正規化は画像エンコーダ内に内包**し、ImageType は `scale=1/255` のままにする（アプリの入力経路を不変に保つ／旧 MobileCLIP は mean/std 無しだった点と異なる）。imageSize は config 経由（ViT-B-32 は 224）。モデルを変えたら `AutoAlbumSettingsKeys.perceptionVersion` を採番して全再埋め込み。fp16 は一部シミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落として安全に無効化する（**画像タワーの検証・本番は実機**。`ImageRecognitionTests` の画像系はシミュレータでスキップ）。未同梱でもアプリは動作し、CLIP 機能だけ無効化される。ランタイム（`MobileCLIPRuntime`）は `MobileCLIPKit` にあり `static let shared` で**遅延ロード**（起動を重くしない）。ロード結果は診断ログに残し、`MobileCLIP.modelsBundled` でロードせず同梱判定できる（Developer Options で可視化）。シミュレータは `.cpuOnly`、実機は `.all`
- **ピープル（顔クラスタ）＝オンデバイス顔認識**: 写真アプリの「ピープル」は**公開 PhotoKit API でアクセス不可**（旧 subtype-1000 方式は誤りで常に空＝撤去）。代わりに **Vision 顔検出＋同梱顔モデル（facenet InceptionResnetV1/VGGFace2・MIT・512次元L2正規化）で identity 埋め込み→逐次クラスタリング**で自前の「人物」を作る。ロジックは `AutoAlbumCore/Faces`（`FaceClustering`（純・コサイン逐次・テスト）/ `FaceStore`（@ModelActor・**別コンテナ "FacesV1"**）/ `FaceTagger`（背景スキャン）/ `PeopleEngine`（@MainActor @Observable ファサード）/ `PersonInfo`（表示値型）/ 純ロジック各種（下記）/ seam `FacePerceptionProvider`・`DetectedFaceSignal`）。実体（Vision+CoreML）は `MobileCLIPKit`（`FaceModelRuntime`・`FacePerceptionAdapter`）。モデルは `MosaicPhotos/FaceModel/`（**`.gitignore` 対象**・`scripts/build_facenet.sh`＋`convert_facenet.py` で生成・FLOAT16）。未同梱なら `isFaceModelAvailable==false` でセクション非表示。**端末写真は 1024px（ADR-51・旧640px）・クラウド写真は Dropbox のキャッシュ済みサムネ**で顔検出（追加DL無し）。人物アルバム表示・代表顔アバターもクラウド対応。パイプライン版（`PeopleEngine.faceScanVersion`）を上げると全再スキャンし、**命名は写真の重なりで持ち越す**（ADR-51）。精度・アルゴリズムは**データセット計測で決める**（`docs/architecture-note/records/face-accuracy.md`＝台帳・FG-NET/LFW・`FaceAccuracyEvalTests`／`FaceEvalMetrics`）。
  - **検出ゲート（不確かな顔を弾く）**: 検出信頼度<0.8・クロップ再検証（二段検出＝顔中心の切り抜きで再検出できないものを棄却）・ぼけ（ラプラシアン分散）・露出（平均輝度）・絶対48px/正規化サイズ比・顔向き（yaw≥30°/roll≥45°）・目閉じで品質を減衰し、品質フロア 0.40 未満はクラスタへ入れない（記録は残す）。しきい値は `FaceQualityGate` に集約（ADR-48/52/53）。偽陽性は計測で 0%。
  - **埋め込みの安定化**: 両目ランドマークで**アライメント**（目線を水平・標準位置へ正規化＝facenet の学習形式）＋**マルチクロップ平均**（アライメント/水平反転/bbox の3埋め込み）＋EXIF 回転の正規化（ADR-51/54）。
  - **クラスタリング（既定しきい値 0.50・校正で 0.35〜0.70）**: マージンゲート（1位と2位の差が 0.05 未満の紛らわしい顔は入れない）＋サイズ適応マージン（小/新クラスタほど合流を厳しく）＋同一写真 cannot-link＋共起 notSame。夜間に制約付き再クラスタ（品質降順・命名/確認クラスタを種に保持）。混入率は初期 58%→**12%**（FG-NET・ADR-56〜58）。
  - **ユーザー修正から学習**（ADR-45/46）: 品質重み＋負例エグゼンプラ（`FaceCorrection` に埋め込みで永続化＝再スキャン・モデル更新を跨いで再発防止）・確認済み顔をアンカー（マルチプロトタイプ）・しきい値のユーザー校正。**レビュー**（「同じ人物ですか？」カード＝`FaceReviewView`）で判断が割れるケースだけ尋ねる。
  - **2 階層の人物束ね**（ADR-61）: 成長で複数クラスタに分かれた子供を **1 人物として束ねる**（`personGroupID`・**融合せず各クラスタの純度を保つ**・後で解除可）。子供は撮影日（`DetectedFace.captureDate`≒年齢）で時期グループ、大人は融合。表示・検索・名前・顔ハイライトは束ねを反映。純ロジックは `FacePersonGrouping`。「束ねる＝子供」なので年齢推定 API・VLM 判定は不要。
  - **顔ハイライト**: 人物アルバムの下部バー「顔を表示」トグルで、認識した顔（束ねた全時期）をサムネ/全画面で黄枠表示（`faceHighlightProvider`／`FaceBoxMapping`・PhotoSourceKit は AutoAlbumCore 非依存を維持）。
- **端末診断（Diagnostics）**: 実機で Mac/Console なしに不具合を追えるよう、`MosaicSupport.Diagnostics.install()`（アプリ `init()` で呼ぶ）が未捕捉 ObjC 例外（`NSSetUncaughtExceptionHandler`）とメモリ圧迫（`DispatchSource`）を `Caches/diagnostics.log` へ記録する。`LogChannel` の `error` は Release でも、`info`/`verbose` は DEBUG のみ同ログへ転記。Developer Options の `DiagnosticsLogView` で閲覧・共有・クリアできる。※ Swift の `fatalError`/SwiftData trap はこのハンドラを通らない（標準クラッシュログ側）
- **パフォーマンス計測（PerfTrace）**: 重い経路の所要/回数を測る常駐の計測 seam＝`MosaicSupport.PerfTrace`。既定無効で無効時は即 return（オーバーヘッド無視可）＝計測コードをコードに残せる。ON/OFF は `-DMOSAIC_PERF`（既定 ON）か実行時 `PerfTrace.isEnabled`（Developer Options のトグル「Performance tracing」・`AppSettingsKeys.perfTracing` で永続化・起動時反映）。出力は os_signpost と DiagnosticsLog。API は `measureAsync`/`logSpan`/`mark`/`count`+`flushCounters`、**画面遷移は `beginScreen`/`endScreen`**（遷移トリガで begin、遷移先 onAppear で end＝所要 ms を `screen.*` に出す。SwiftUI 側ヘルパは `View.perfScreenEnd(_:)`＝PhotoSourceKit）。現状の計測点は (1) **画面遷移**（`home.present`＝ホーム→各フルスクリーン、`home.settings`＝設定シート、`open.photo`＝グリッド→フル写真、`grid.<title>`＝ソース画面 onAppear→初回コンテンツ確定）、(2) Dropbox（`net.<endpoint>`＝`DropboxAPIClient.send`、サムネ集計＝`DropboxThumbnailBatcher`、`cache.thumb.*`/`cache.fetchItems`＝`DropboxCacheStore`、`fullImage.*`＝`DropboxPhotoStore`）。新たに測る時も同じ seam を使う
- **DropboxKit のキャッシュ機構**: `DropboxPhotoStore` は `DropboxCacheStore`（`actor`）を介してファイル一覧・サムネイル・本体画像をキャッシュする。メタデータは SwiftData（`CachedDropboxItem` / `DropboxSyncState` / `CacheUsageEntry`）、バイナリは `ImageCacheKit` の `MemoryImageCache` + `DiskImageStore` で `Caches/DropboxKit/{thumbnails,fullimages}/` 配下にハッシュ化ファイル名（`DropboxCacheNaming`）で保存する。`contentHash` 変更検知による無効化と、`CacheUsageEntry`（最終アクセス日時）ベースの LRU 容量管理を行う
- **サムネ取得は2段優先キュー（`DropboxThumbnailBatcher`）**: 可視セル要求（`thumbnail(for:)`・待機者あり）=最優先 FIFO、先読み（`prefetch`・待機者なし）=低優先 LIFO＋上限（既定600）。各ウェーブは可視→先読みの順で `get_thumbnail_batch`（25枚×最大 `maxConcurrentRequests` 並行）。`cancelPrefetchingForItemsAt`→`PhotoLoading.cancelPrefetch`→`cancelPrefetch` で**画面外の未取得先読みを破棄**（行列が深くなり可視取得が待たされるのを防ぐ）。先読みは `DropboxCacheStore.thumbnailExists`（メモリ/ディスク存在を非デコード判定）で既存分を除外、`inFlight` で二重フェッチ防止。ドレイン中は `BackgroundActivityMonitor.cloudThumbnailBusy` を立て背景 CLIP に譲らせる。サムネのメモリ層の上限は**端末のメモリ予算から算出**する（`MosaicSupport.MemoryBudget`＝`os_proc_available_memory()`、取得不可は physicalMemory の一部。`thumbnailCostLimit(budget:)` で予算の約5%を 60〜192MB にクランプ・件数/圧迫下限はそこから導出）。固定値だと低RAM機でjetsam・高RAM機で取りこぼし（ディスク再デコード増）になるため、**起動時に予算からベースを決め、圧迫時の動的縮小は MemoryPressureMonitor に任せる二段構え**。**critical 圧迫でも全消去しない**（`MemoryImageCache(purgeOnCritical:false)`＝段階縮小に留め、ディスク再デコードの storm を防ぐ）。デコード（ディスク）の同時数は `ThumbnailDecode.limiter`（`AsyncSemaphore`・`max(6, コア数×2)`）で制限し、無制限 `Task.detached` による CPU 競合を避けつつ行列を浅く保つ（ネット応答デコードはバッチ並行数で既に有界＝セマフォ分離）。ネット並行数（`maxConcurrentThumbnailRequests`）は CPU/メモリではなく Dropbox レート制限で決まるので**固定（ユーザー設定）**にする初回同期の UI 反映は状態依存に間引く（`DropboxPhotoStore` の `currentRefreshInterval`：initialSync=5s/polling=0.4s、完了時 `forceCacheRefreshSoon` で即時最終反映）
- **画像キャッシュの共通化（ImageCacheKit）**: メモリ（`MemoryImageCache`）+ ディスク I/O（`DiskImageStore`）のプリミティブは `ImageCacheKit` に集約し、`LocalPhotoCore`（`ThumbnailCache`）と `DropboxCore`（`DropboxCacheStore`・SwiftData LRU）の双方が利用する。**破棄ポリシー（LRU）は各利用側が持つ**（`DiskImageStore` 自体は持たない）。`DiskImageStore` のコアは Foundation のみで macOS テスト可能、`UIImage` 便宜メソッドのみ `#if canImport(UIKit)` 拡張
- **ロギングの共通化（MosaicSupport）**: `os.log` + `print` + DEBUG ゲートのパターンは `MosaicSupport` の `LogChannel`（subsystem / ラベルを引数化）に集約する。各パッケージのロガー（`DropboxLogger` / `BackupLogger`）は `LogChannel` への薄い委譲とし、`verbose` / `info` は DEBUG のみ、`error` は常に記録する
- **テスト用 seam（DI）**: 外部依存はプロトコルで抽象化しデフォルト引数で本番実装を注入する。`HTTPClient`（URLSession）/ `DateProvider`（時刻）/ `AccessTokenProvider`（トークン）を `DropboxThumbnailBatcher` / `DropboxSyncEngine` / `DropboxAuthService` / `BackupEngine` へ注入。テストはスタブを渡す。新規にネットワーク/時刻/トークンへ依存するコードは `URLSession.shared` / `Date()` を直書きせずこれらを使う
- **Dropbox API リクエストの集約**: 認証ヘッダ付与・ステータス検証を伴う RPC / content ダウンロードは `DropboxAPIClient`（`rpc` / `contentDownload`）に集約する。longpoll（認証不要・専用タイムアウト）など特殊なものは `HTTPClient` を直接使う
- **設定キーの一元化**: `@AppStorage` / `UserDefaults` のキー文字列は各パッケージの専用 enum に集約する（`GridSettingsKeys`（ズーム段階 `zoomLevel`・月グループ密度 `monthSectionRows`）/ `CacheSettingsKeys` / `DropboxCacheSettingsKeys`（サムネ並列数 `thumbnailConcurrency` を含む）/ `BackupSettingsKeys` / `AutoAlbumSettingsKeys`（生成/知覚バージョン・背景処理段階など）/ アプリ層は `AppSettingsKeys`）。文字列リテラルを読み手・書き手に重複させない
- **写真ソースインターフェイスの統一**: `LocalPhotoCore` / `DropboxCore` / `PhotosFeatureKit` のストアは、操作・表示インターフェイス（一覧取得・状態管理・サムネイル/フル画像取得・グリッド/詳細表示）を `PhotoSourceKit` の `PhotoItem` / `PhotoLoadState` / `PhotoStore` プロトコルと汎用ビューに統一する。アイテム単位のローディング（thumbnail/fullImage/prefetch/location/metadata）は `PhotoLoading` プロトコルに分離し、`PhotoStore: PhotoLoading` として精緻化している（`Store: PhotoStore` 制約だけで両方のメソッドを利用できる）。`init` の設定パラメータ（`DropboxAuthService` 等）は各パッケージ固有のまま維持する
- **Dropbox API キーの一元管理**: `appKey` と `redirectURI` はアプリターゲットの `MosaicPhotos/DropboxConfig.swift`（`enum DropboxConfig`）に定義する。`DropboxCore` には設定値を持たせず、`HomeView` がここを参照して `DropboxAuthService.init(appKey:redirectURI:)` に渡す

- **UI 言語 / 国際化（i18n）**: ユーザー向け文字列の **base（原文）は英語**で記述する（日本語をハードコードしない）。国際化は **String Catalog（`.xcstrings`）** で行う（base=英語、追加言語＝日本語ほか・機械翻訳）。方式は **per-package（案A）**：各 UI パッケージは `Package.swift` に `defaultLocalization: "en"` ＋ `resources: [.process("Localizable.xcstrings")]` を宣言し（**SwiftPM CLI は `.xcstrings` を自動認識しないため明示必須**。無いと `Bundle.module` 不生成で `swift test` が落ちる）、パッケージ内 UI 文字列は小ヘルパー **`L(_:)`**（＝`String(localized:bundle:.module)`）で包む（`Text`/`Label`/`Button`/`Section`/`navigationTitle` 等は `String` を verbatim 表示するため一様に効く。`Text("x")` 直書きは既定で `Bundle.main` を見るため不可）。**アプリ本体**は `Text("x")` リテラルが `Bundle.main` を見るのでコード改変不要、`MosaicPhotos/Localizable.xcstrings` ＋ `project.pbxproj` の `knownRegions` に言語追加。**Developer Options/Debug は対象外（英語のまま）**。動的 String（`Text(変数)` は verbatim＝未翻訳）は `LocalizedStringResource`/`String(localized:)` 化が必要。日付/数値/地名はロケール対応の API を使う（ADR-17）
- **文字コード**: ソースコード・API リクエスト/レスポンスボディ・Keychain 保存値はすべて UTF-8 を使用する。Swift の `String` / `Data` デフォルト（`.utf8`）を維持し、他のエンコーディングを混在させない
- **開発者向けドキュメント**: コメント・コミットメッセージは日本語で構わない

- **設計判断・事例の記録（必須・マスターは Markdown）**: 設計上の判断、埋め込んだバグ、原因が非自明だった不具合、性能/メモリ/起動などの大きめの課題対応を行ったら、**必ず** Markdown のマスターに 1 項追記して網羅する。これらの記録はチャット履歴に頼らず、リポジトリ内に確実に残す。
  - マスター（正本）: `docs/architecture-note/records/decisions.md`（設計判断＝ADR）/ `docs/architecture-note/records/case-studies.md`（事例・バグ・課題対応）/ `docs/architecture-note/records/background-behavior.md`（**どの設定だと何が動くかの早見表**＝ゲートを足す/変えるたびに更新）。各ファイル冒頭の「運用ルール」と「テンプレート」に従う（ADR は `## ADR-N` 連番＋文脈/決定/結果、事例は症状/原因/対処/関連/残課題）。
  - HTML（`docs/architecture-note/design-decisions/adr.html` / `case-studies/*.html`）は MD からの**派生物**で、**指示に応じて取捨選択**して記載する（全件転記しない）。HTML 目次の定義は `docs/architecture-note/assets/nav.js` の `NAV` 配列が唯一の出典。
  - 順序: まず MD に追記（網羅）→ 必要なら HTML 化（選択）。撤回・変更時は MD の項を消さず状態を追記して経緯を残す。

---

## 外部スキルとの優先順位

Apple フレームワークの一般リファレンス（Claude Code スキル `coreml` / `vision-framework` /
`apple-on-device-ai` ほか。導入手順は `CONTRIBUTING.md`）を併用する。導入は任意で、
プロジェクト直下の `.claude/skills/`（`.gitignore` 対象）にあるためコードからは見えない。

**スキルは一般論、本ファイルと `docs/architecture-note/records/*.md` は実測に基づく決定**。
矛盾したら後者が勝つ。特に以下はスキルの推奨と意図的に異なるので、「直す」対象ではない：

- **ANE の直列化（`PerceptionCore/MLInferenceGate`）**: Vision の `perform` と Core ML 推論が
  ANE を同時に使うと実機でデッドロックした（diagnostics-19）。ANE を使う重い処理は**同時に 1 つ**。
  スキルには無い制約なので、推論・モデルロードを足すときは必ずゲートを通す。
- **`computeUnits = .cpuAndNeuralEngine`（実機）**: スキルの既定は `.all` だが、GPU は UI 合成
  （Metal）と食い合うため意図的に除外している。シミュレータは `.cpuOnly`（ANE 不在で Espresso 例外）。
- **レガシー `VN*` API を使用**: スキルは iOS 18+ の新 Vision API を推奨するが、顔パイプラインは
  データセット計測でしきい値を校正済み（`face-accuracy.md`）。API 移行は数値の再校正を伴うため行わない。
- **モデルは `Bundle.main` 同梱＋`.gitignore`**: スキルの Background Assets / ODR は採らない
  （通信なし・API キー不要が要件）。生成は `scripts/build_*.sh`。

一方、スキルが**足りない部分を埋めるのは歓迎**（`MLComputePlan` によるデバイス割り当て確認、
メモリ圧迫時のモデル解放、`MLModel.load` の async ロード等）。採用したら本ファイルに追記する。