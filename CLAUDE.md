# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**MosaicPhotos** は iOS (iPhone) 向けの写真ビューワーアプリ。端末内の写真と Dropbox 上の写真を、ソース別（All / Photos / Cloud）・端末アルバム別・場所（市区町村）別に閲覧できる。外部 SDK は使用せず、すべて標準フレームワークで実装している。

加えて **オンデバイス AI** を持つ：自然文（任意言語）の **AI アルバム / 意味検索**を「タグ台帳＋LLM審査」の多層構成（ADR-23/24）で実現する。索引は夜間バッチ（電源＋アイドル/ロック中 BGTask）で **Vision シーンタグ（約1,300クラス・精度校正済み）→ CLIP 埋め込み（OpenCLIP ViT-B-32・INT8量子化・Core ML・ADR-31）→ VLM キャプション（SmolVLM-500M・**お気に入り限定**・任意同梱）** の順に付与（タグ/埋め込みは全写真・キャプションはお気に入りのみ）。検索は「決定的ハード条件（日付=RelativeDateParser・場所/人物接地・レキシコン）→ タグ一致＋CLIP 対比＋字句の RRF 融合 → 証拠ゲート → FM LLM 審査（多数決）」。解釈（LLM）はアルバム作成時に 1 回だけ実行して永続化する。通信なし・API キー不要。


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
| オンデバイス AI | 多層構成（ADR-24）: **Vision 画像分類**（OS 内蔵・約1,300クラス・`hasMinimumRecall(forPrecision:)` の校正済み足切り）＋ **OpenCLIP ViT-B-32（DataComp・MIT・INT8量子化＝容量半減/精度ほぼ不変・ADR-31）**（Core ML・画像/テキスト埋め込み。ファイル名 `MobileCLIP*` は互換のため据え置き）＋ **SmolVLM-500M-Instruct（Apache-2.0・任意同梱・お気に入り写真限定）**（写真キャプション・`scripts/build_smolvlm.sh` で生成。**視覚エンコーダのみ INT8 量子化**＝出力ベクトルは量子化に強く cos≈0.999／言語デコーダは次単語 argmax が敏感で fp16 のまま。合計 877MB。重い文章生成なので**お気に入り（PHAsset favorite）のみに付与**＝ADR-34。※ 256M より高品質だがメモリ大／FastVLM は apple-amlr で不採用／Florence は ANE 破綻で撤回＝ADR-32）。クエリ解釈・翻訳・候補審査は Apple Foundation Models（`FoundationModels`）で、解釈は**作成時 1 回・永続化**（ADR-23）＋防御的サニタイズ＋決定的レキシコン。ロジックは `AutoAlbumCore`、各ランタイム/seam 実装は `MobileCLIPKit` に集約 |
| 端末診断 | `MosaicSupport` の `Diagnostics`：未捕捉例外（`NSSetUncaughtExceptionHandler`）・メモリ圧迫（`DispatchSource`）・各ログを `Caches/diagnostics.log` に追記し、Developer Options で閲覧/共有（実機で Mac/Console なしに原因追跡） |
| 最小 iOS | iOS 26.0（アプリターゲットの `IPHONEOS_DEPLOYMENT_TARGET`。各 SPM パッケージは `.iOS(.v17)` 宣言＋`@available` ゲートで macOS テストも維持） |
| パッケージ管理 | Swift Package Manager（ローカルパッケージ 11 個。基盤: `MosaicSupport` / `PhotoSourceKit` / `ImageCacheKit`、ローカル写真: `LocalPhotoCore`(ロジック) / `LocalPhotoKit`(UI)、Dropbox: `DropboxCore`(ロジック) / `DropboxKit`(UI)、`BackupKit`、写真機能統合: `PhotosFeatureKit`、自動アルバム/AI: `AutoAlbumCore`、CLIP ランタイム/AI seam 実装: `MobileCLIPKit`） |

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

### ファイル構成

```
MosaicPhotos/                      ← メインアプリターゲット（合成のみの薄い層）
  MosaicPhotosApp.swift            エントリーポイント。WindowGroup に HomeView を配置。init() で Diagnostics.install()
  HomeView.swift                   ルート画面。Sources（All/Photos/Cloud）+ Albums + Places。単一 HomeDestination enum + 1 fullScreenCover で遷移。起動後タスクは段階起動（place scan/backup/AI を時差で開始）
  DropboxConfig.swift              アプリ固有の Dropbox OAuth 設定値（redirectURI 等）
  DropboxSecrets.swift             appKey 等のシークレット（.gitignore 対象）
  SettingsView.swift               「設定」シート。Settings.app 風のグルーピング List をルートに、各設定へ NavigationLink
  Home/
    SourceHostView.swift           各ソースのフルスクリーン共通ラッパー（dismissToHome / showSettings / photoInsight を環境注入）
    HomeSections.swift             HomeView の各セクション（Sources / Albums / Places）を分割
    HomeRows.swift                 SourceRow / LibraryRow / AlbumRow / PlaceRow ＋共通カバーローダ
    AlbumCarousel.swift            アルバムの横スクロールカルーセル表示
    PlacePhotosView.swift          場所アルバム表示（メンバー限定 MergedPhotoStore）
    AutoAlbumPhotosView.swift      生成アルバム（旅行/フォルダ/AI）の写真表示
    AutoAlbumAdapters.swift        Composition Root。AutoAlbumEngine に各 seam（Cloud/Backup/People/CLIP/翻訳/ラベラ）を結線
    AutoAlbumSettingsView.swift    AI/旅行/フォルダ生成＋画像認識（再解析・背景処理速度段階）
    AIAlbumComposerView.swift / PathAlbumSettingsView.swift / PlacesSettingsView.swift  各設定/作成ビュー
  Settings/
    SettingsView は上記。以下は設定の各画面・キー。
    DropboxHubView.swift           Dropbox のハブ（接続設定＋バックアップ＋フォルダアルバムを集約）
    StorageSettingsView.swift      ストレージ/キャッシュ説明・上限設定
    DeveloperSettingsView.swift    Developer Options。各パッケージの Debug セクション（DropboxDebugSection 等）＋診断（メモリ/CLIP 同梱/ログ）を合成
    DiagnosticsLogView.swift       端末上の診断ログ（diagnostics.log）の閲覧・共有・クリア
    AppSettingsKeys.swift          アプリ層の @AppStorage キー集約
  MobileCLIP/                      CLIP の Core ML モデル＋語彙（.gitignore 対象・scripts/build_mobileclip.sh で生成）
  FaceModel/                       顔認識モデル（.gitignore 対象・scripts/build_facenet.sh で生成）
  VLM/                             SmolVLM（キャプション・.gitignore 対象・scripts/build_smolvlm.sh で生成）
  HeavyWorkScheduler.swift         BGProcessingTask（ロック中の夜間処理＝タグ/埋め込み/キャプション/生成）

Packages/MosaicSupport/            ← 最下層 SPM パッケージ（横断ユーティリティ・依存なし）
  Sources/MosaicSupport/
    LogChannel.swift               os.log + print + DEBUG ゲートを集約した共通ロガー（各レベルを DiagnosticsLog にも転記）
    Diagnostics.swift              DiagnosticsLog（Caches/diagnostics.log へロールリング追記・閲覧/共有/クリア）/
                                   currentMemoryFootprintMB() / Diagnostics.install()（未捕捉例外＋メモリ圧迫を記録）
  ※ DropboxCore / BackupKit / MobileCLIPKit / アプリが依存。各パッケージのロガーは LogChannel に委譲する

Packages/PhotoSourceKit/           ← 写真ソース共通基盤（表示インターフェイス・純ロジック）
  Sources/PhotoSourceKit/          ← 責務ごとにサブフォルダで整理（すべて同一モジュール）
    Interface/                     PhotoItem / PhotoLoading（アイテム取得）/ PhotoStore(: PhotoLoading)/
                                   PhotoLoadState（権限/通信/完了/失敗の状態 enum）/
                                   PhotoInsight（フル画像の付加情報＝表示タグ・人物・解析状態。SwiftUI 非依存値型）
    Views/                         PhotoSourceContentView（状態分岐＋全状態に下部 Home/Settings バー）/
                                   PhotoGridView / PhotoCollectionView（UICollectionView グリッド・diffable・プリフェッチ・
                                   contentOffset ベースのスクラバー）/ GridThumbnailCell / GridSectionHeaderView /
                                   GridScrubberView / FullPhotoView / PhotoInfoPanel / PhotoPageView /
                                   PhotoSourceEnvironment（dismissToHome / showSettings）/ GridSettingsKeys
    Places/                        GeoGridKey(純)/ PlaceAlbumInfo / PlaceGrouping(純)/
                                   PlaceNameResolver(actor・**オフライン**地名解決 + 地名キャッシュ)/
                                   OfflinePlaceDB(同梱 cities15000.bin で最近傍逆ジオコーディング・ネット不要)
    Support/                       PhotoGridGrouping(日付グルーピング純)/ PhotoItemSorting(純)/
                                   PhotoExifInfo(EXIF 解析+parse 純)/ JSONFileStore<T>(JSON 永続化)
  Tests/PhotoSourceKitTests/       grouping/sorting/exif/geo/jsonstore/place の単体テスト（macOS）

Packages/ImageCacheKit/            ← 画像キャッシュ共通プリミティブ・SwiftUI 非依存
  Sources/ImageCacheKit/
    MemoryImageCache.swift         NSCache ラッパー（メモリ層）
    DiskImageStore.swift           ディレクトリ単位のディスク I/O + LRU 列挙（コアは Foundation のみ）
  Tests/ImageCacheKitTests/        DiskImageStore の LRU/IO テスト（macOS）
  ※ LocalPhotoCore（ThumbnailCache）と DropboxCore（DropboxCacheStore）が共用。破棄ポリシーは各利用側が持つ

Packages/LocalPhotoCore/           ← 端末写真のロジック層（PhotoSourceKit / ImageCacheKit に依存）
  Sources/LocalPhotoCore/
    LocalPhotoStore.swift          @MainActor @Observable。PHAsset 一覧管理・権限処理
    LocalPhotoStore+PhotoStore.swift  PhotoStore 適合（サムネイル/フル画像取得・#if canImport(UIKit)）
    LocalAlbumScanner.swift        アルバム走査（バックアップと独立。JSONFileStore でキャッシュ）
    （ピープル＝旧 subtype-1000 方式は撤去。PhotoKit に公開 People API が無いため、
                                   Vision 顔検出＋同梱顔モデルの自前クラスタリングへ作り直した＝AutoAlbumCore/Faces）
    LocalAlbumInfo.swift           アルバム情報値オブジェクト
    LocalPhotoItem.swift           PHAsset を束ねる PhotoItem
    ThumbnailCache.swift           actor。MemoryImageCache + DiskImageStore による LRU キャッシュ
    MetadataCache.swift / MetadataPreloader.swift  PHAsset メタデータの先読み
    CacheSettingsKeys.swift        サムネイルキャッシュの永続設定キー（public）
  Tests/LocalPhotoCoreTests/       LocalPhotoStore の初期状態テスト（macOS）

Packages/LocalPhotoKit/            ← 端末写真の UI 層（LocalPhotoCore / PhotoSourceKit に依存）
  Sources/LocalPhotoKit/
    LocalPhotoCore.swift           @_exported import LocalPhotoCore（再エクスポート）
    LocalPhotoContentView.swift    「写真」タブルートビュー
    LocalPhotoSettingsView.swift   端末写真ソース設定ビュー（キャッシュ上限）
    LocalThumbnailView.swift       PHAsset サムネイルセル
    LocalPhotoPageView.swift       PHAsset フルスクリーンページングビュー

Packages/DropboxCore/              ← Dropbox のロジック層（ImageCacheKit / MosaicSupport に依存・SwiftUI 非依存）
  Sources/DropboxCore/             ← 責務ごとにサブフォルダで整理（すべて同一モジュール）
    Auth/                          DropboxAuthService（OAuth2 + PKCE）/ PKCEGenerator(純)/
                                   DropboxCredential / CredentialStore / DropboxKeychainStore
    Networking/                    HTTPClient(抽象)/ DropboxAPIClient(RPC・DL 集約)/
                                   DropboxAPIArgEncoder / DropboxInternalConstants
    Sync/                          DropboxSyncEngine(差分同期)/ DeltaPageParser(解析・純)/
                                   DropboxSyncState(@Model カーソル)
    Cache/                         DropboxCacheStore(actor・SwiftData+ImageCacheKit)/
                                   DropboxCacheNaming(純)/ CachedDropboxItem / CacheUsageEntry(@Model)/
                                   DropboxCacheDebugModel
    Models/                        DropboxFileItem / DropboxMediaInfo / DropboxBackupMetadata
    Store/                         DropboxPhotoStore(@Observable)/ DropboxThumbnailBatcher
    Support/                       DateProvider / AccessTokenProvider / DropboxLogger(→LogChannel)
  Tests/DropboxCoreTests/          APIClient/AuthService/PKCE/SyncEngine/DeltaParser/Batcher/Cache/Naming/MediaInfo/Metadata（iOS Sim）

Packages/BackupKit/               ← 端末写真→Dropbox バックアップ（DropboxCore / MosaicSupport に依存）
  Sources/BackupKit/
    BackupEngine.swift             @MainActor @Observable。バックアップのオーケストレーション
    DropboxBackupUploader.swift    写真/metadata の HTTP アップロード（認証・SwiftData から独立・テスト対象）
    BackupAssetReader.swift        PHAsset 本体データの取得
    BackupIndexing.swift           People/Album インデックス構築（top-level・Task.detached 用）
    BackupPlanning.swift           アップロード差分算出・エラー要約の純ロジック（テスト対象）
    BackupSettingsKeys.swift / BackupDestination.swift  設定キー / 値オブジェクト
    BackupSettingsView.swift       バックアップ通常設定ビュー（#if canImport(UIKit)）
    BackupDebugSection.swift       Developer Options 向け詳細診断セクション（進捗/フォルダ確認/統計/ログ・public）
    BackupLogger.swift             内部ロガー（MosaicSupport の LogChannel に委譲）
    BackupAlbumInfo.swift / BackupAssetRecord.swift  値オブジェクト / @Model
  Tests/BackupKitTests/            BackupPlanning / DropboxBackupUploader のテスト（macOS）

Packages/DropboxKit/               ← Dropbox の UI 層（DropboxCore / PhotoSourceKit に依存）
  Sources/DropboxKit/
    DropboxCore.swift              @_exported import DropboxCore（再エクスポート）
    DropboxContentView.swift       「クラウド」タブルートビュー
    DropboxSettingsView.swift      Dropbox 通常設定ビュー（接続・サムネ並列数・キャッシュ上限）
    DropboxDebugSection.swift      Developer Options 向け詳細診断（トークン/キャッシュ状態/再同期/定数・public）
    DropboxThumbnailView.swift     Dropbox ファイルサムネイルセル
    DropboxPhotoPageView.swift     Dropbox フルスクリーンページングビュー
    DropboxCacheListView.swift     キャッシュデバッグ一覧ビュー
    DropboxCacheSettingsKeys.swift Dropbox キャッシュ上限の永続設定キー
    DropboxPhotoStore+PhotoStore.swift  PhotoStore プロトコル適合
    DropboxFileItem+PhotoItem.swift     PhotoItem プロトコル適合
  Tests/DropboxKitTests/           DropboxAPIArgEncoder / DropboxFileItem のテスト（macOS）
  TestApp/                         DropboxKit 単体動作確認用の iOS テストアプリ（独自 .xcodeproj）

Packages/PhotosFeatureKit/         ← 写真機能の統合層（DropboxKit / LocalPhotoKit / PhotoSourceKit に依存）
  Sources/PhotosFeatureKit/
    MergedPhotoStore.swift         @MainActor @Observable。Local + Dropbox を統合する PhotoStore
    MergedPhotoItem.swift          ローカル/クラウドを束ねる PhotoItem（enum・id プレフィックスで衝突回避）
    PlaceScanner.swift             @MainActor @Observable。Local+Dropbox の位置情報を市区町村にグルーピング
  Tests/PhotosFeatureKitTests/     filter/state/MergedPhotoItem/placeScanSignature のテスト（iOS Sim）

Packages/AutoAlbumCore/            ← 自動アルバム＋オンデバイス AI のロジック層（SwiftUI 非依存・MosaicSupport に依存）
  Sources/AutoAlbumCore/
    AutoAlbumEngine.swift          @MainActor @Observable ファサード。生成/AI/フォルダ/タグ付けを協調
    PhotoRef.swift                 "L-…"/"C-…" のエンコード（ローカル/クラウド統一キー・純）
    EnrichedPhoto.swift / BackgroundProcessing.swift  付加情報の値型 / 背景処理の重さプリセット（純）
    Models/                        PhotoEnrichment(@Model・メタデータのみ) / PhotoEmbedding(@Model・CLIP埋め込みを
                                   Float16 で別テーブル化) / GeneratedAlbum(@Model)
    Store/                         AutoAlbumStore(@ModelActor・SwiftData。埋め込み/アルバム永続化)
    Perception/                    PhotoPerceptionProvider / TextEmbedder / QueryTranslator / LabelProvider
                                   （seam・実体はアプリ側）/ PhotoTagger(背景 CLIP 埋め込み・スロットル) / PhotoEnricher
    AIAlbum/                       AIAlbumService（解釈永続化・増分/フル再評価・証拠ゲート・審査）/
                                   AIAlbumSearcher（タグ一致＋CLIP対比＋字句の RRF 融合）/ AlbumVerifier(FM審査) /
                                   AIAlbumInterpretationStore(解釈の永続化・版管理) / QuerySpecSanitizer(防御的接地) /
                                   JapaneseVisualLexicon(決定的視覚語/人物否定) / ClipMath(vDSP コサイン) /
                                   LexicalSearch(地名/人物) / RelativeDateParser(日英・日付の唯一の出典) /
                                   QueryUnderstanding(RuleBased) / FoundationModelsQueryUnderstanding(iOS26)
    Tags/                          TagStore(@ModelActor・TagsV1 別コンテナ・シーンタグ+キャプション) /
                                   TagTagger(夜間トリクル付与)
    Strategies/                    TimePlaceStrategy(旅行抽出) / PathAlbumStrategy(フォルダ名) / CoverSelection 他
  Tests/AutoAlbumCoreTests/        search/lexical/clipmath/strategy/path/background のテスト（macOS）

Packages/MobileCLIPKit/            ← CLIP/翻訳ランタイム＋AutoAlbumCore seam のアプリ側実装（AutoAlbumCore / MosaicSupport に依存）
  Sources/MobileCLIPKit/
    MobileCLIPRuntime.swift        MobileCLIP 画像/テキストエンコーダ（Core ML・遅延ロード static shared・ロード結果を診断ログへ）。
                                   MobileCLIP.modelsBundled でロード不要の同梱判定
    CLIPTokenizer.swift            BPE トークナイザ
    AIPerceptionAdapters.swift     PhotoPerceptionProvider（refKey→ローカル/クラウド画像→CLIP 埋め込み）/ MobileCLIPTextEmbedder
    AILanguageAdapters.swift       AppQueryTranslator（FM 英訳）/ loadLocalCGImage（共通画像ローダ）
    CLIPDisplayLabeler.swift       表示タグ補完：約300語に対する CLIP ゼロショット（保存済み clipVector を使用）
    VisionTagAdapter.swift         シーンタグ（OS 内蔵 VNClassifyImageRequest・精度校正済み足切り）＋VLM キャプション seam
    VLMRuntime.swift               SmolVLM 実行系（視覚埋め込み→固定長全系列デコード・遅延ロード）
    GPT2Tokenizer.swift            SmolLM2 用 byte-level BPE（vlm_vocab/merges から構築）
  ※ アプリの AutoAlbumAdapters がこれらを AutoAlbumEngine の seam に注入する
```

### コンポーネント関係

```
MosaicPhotosApp
  └── HomeView  (@State dropboxStore / mergedStore / backupEngine / albumScanner / placeScanner)
        ├── [All Photos] PhotoSourceContentView(store: MergedPhotoStore)   ← import PhotosFeatureKit（Local + Dropbox 統合）
        ├── [Photos]     LocalPhotoContentView      ← import LocalPhotoKit（LocalPhotoStore）
        ├── [Cloud]      DropboxContentView         ← import DropboxKit（DropboxPhotoStore）
        ├── [Albums]     端末アルバム / Time&Place 旅行 / フォルダ名 / AI アルバム ← AutoAlbumEngine
        ├── [People]     ピープル（顔クラスタ）← PeopleEngine（Vision 顔検出＋同梱顔モデルで埋め込み→逐次クラスタリング・端末写真640px＋クラウド128px）。Time&Place 直下・顔モデル未同梱なら非表示
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
- **ModelContainer は自己修復で構築**: SwiftData の `ModelContainer` 初期化は、ストア破損・スキーマ不整合のとき起動時に trap して実機で原因不明のクラッシュになりやすい。`AutoAlbumStore` / `DropboxCacheStore` / `BackupEngine` は `makeResilientContainer(...)` で「失敗→ストアファイル（.store/-wal/-shm）削除して再試行→なお失敗ならインメモリ」とフォールバックし、起動を止めない（失敗は診断ログへ）
- **CLIP 埋め込みは別テーブル＋Float16＋ページング**: 埋め込みを `PhotoEnrichment` に inline 格納すると、SwiftData は全件 fetch（生成・重複排除・戦略・prune）のたびに巨大 blob も展開し、67k×2KB≈138MB を確保 → **写真枚数に比例した実機起動クラッシュ**になっていた。そのため埋め込みは **`PhotoEmbedding` 別テーブルに Float16（約1KB/枚）** で分離し、メタデータ fetch が blob に一切触れないようにする。意味検索は `enrichmentVectorPage(offset:limit:)`（`PhotoEmbedding` を refKey 昇順でページング・fp32 へ復元して返す）を `AIAlbumSearcher.search(baseLite:...loadPage:)` にストリームする。`allEnrichedPhotosLite()` はメタのみ（埋め込みなし）。純関数版 `search(_ all:)` と選定ロジックは一致させる。大量 upsert は `writeChunk` 件ごとに使い捨て `ModelContext` で save→解放して常駐を有界に保つ
- **AI アルバム検索は「タグ台帳＋LLM審査」の多層構成（ADR-23/24）**: 解釈（LLM・`FoundationModelsQueryUnderstanding`）は**作成/編集時に 1 回だけ**実行し `AIAlbumInterpretationStore`（JSONFileStore・版管理）へ永続化する（起動時・写真追加時に LLM は走らない）。小型 LLM の構造化出力は信用せず、`QuerySpecSanitizer`（プレースホルダ除去・カタログ丸写し検出・include/exclude 衝突解消）＋**決定的レイヤー**（日付=`RelativeDateParser` が唯一の出典・place/people はカタログ/原文接地・`JapaneseVisualLexicon` で頻出視覚語と人物否定を抽出）で必ず接地する。検索は「ハード条件（`QueryEvaluator`）→ **Vision シーンタグ一致（離散・閾値レス）**＋ CLIP 対比（除外は肯定/否定ベクトルの相対判定のみ・絶対閾値なし）＋字句（`LexicalSearch`）の RRF 融合（`HybridFusion`）→ **証拠ゲート**（除外つきはタグ/顔実測/キャプションの証拠必須）→ **FM LLM 審査**（`AlbumVerifier`・keep/drop/unsure・unsure は最大2回再判定の多数決）→ 空振り時はプローブ拡張で 1 回だけ再検索」。再評価は増分（新規埋め込み分のみ採点しスコアプールへマージ）＋ドリフト検知のフル再評価。旧フラット `AIAlbumQuery` は解釈フォールバック（RuleBased/FM flat）用に残る（検索 API は撤去済み）
- **知覚 seam はプロトコル＋`MobileCLIPKit` 実装**: `PhotoPerceptionProvider`(refKey→CLIP 埋め込み・ローカル/クラウド両対応) / `TextEmbedder` / `QueryTranslator`(Foundation Models) / `LabelProvider`(表示タグ) は `AutoAlbumCore` のプロトコルで、実体は `MobileCLIPKit`（`AIPerceptionAdapters` / `AILanguageAdapters` / `CLIPDisplayLabeler`）が `MobileCLIPRuntime`・`FoundationModels` で実装する。アプリの `AutoAlbumAdapters`（Composition Root）が `AutoAlbumEngine` の seam に注入する。`PhotoSourceKit` は `AutoAlbumCore` に依存せず、フル画像の付加情報は `photoInsight` 環境クロージャ経由で受け取る（レイヤー分離）
- **表示タグ＝検索と同一の台帳**: フル画像のタグ欄（常時表示）は **Vision シーンタグ（`TagStore`・検索の一次ランキングと同一ソース）を第一**に、`CLIPDisplayLabeler`（約300語ゼロショット）で補完する。VLM キャプションも「AI description」欄に表示（生成済みのみ）。タグ/キャプションは **TagsV1 別コンテナ**（`PhotoTagRecord`）で、夜間バッチ（`TagTagger`）が Vision タグ → CLIP 埋め込み → VLM キャプションの順に付与する
- **背景 CLIP 埋め込みのスロットリング**: `PhotoTagger.embedUnprocessed` は小バッチ＋バッチ間スリープ＋`.background` QoS で trickle 実行する。重さは `BackgroundProcessing.presets`（段階）で設定可能（`AutoAlbumSettingsView`・キーは `AutoAlbumSettingsKeys.backgroundProcessingLevel`）。各段は名称＋パラメータ（件数/休止秒）を UI に提示する。**停止判定は 1 枚単位**（`perceive` をバッチ一括でなく 1 枚ずつ呼び、各推論の前に `shouldPause` を確認）で、操作・遷移が来たら即譲れるようにする（8枚一括だとその間 CPU/ANE を握って画面遷移が飢餓する）。`shouldPause` でユーザー操作中（スクラブ）と **メモリ圧迫中（`MosaicSupport.MemoryPressureMonitor.isUnderPressure`）** と **クラウドのサムネ取得中（`BackgroundActivityMonitor.cloudThumbnailBusy`＝Dropbox バッチャのドレイン中）** と **フル画像取得中（`fullImageBusy`＝`DropboxActivityMonitor.beginFullImage` が橋渡し）** と **写真ビュー表示中（`isViewingPhoto`＝タップ直後の遷移含む。`PhotoPageView`/グリッドが報告）** は処理を譲る（メモリ圧迫は `Diagnostics` の warning/critical でフラグ＋自動解除）。**シミュレータでは背景埋め込みを実行しない**（CLIP が `.cpuOnly` で 1 枚数秒〜十数秒かかり遷移を飢餓させ検証の妨げになるため。`#if targetEnvironment(simulator)` で早期 return・実機=ANE の挙動は不変）
- **メモリ圧迫対応は `MemoryPressureMonitor` に集約**: `Diagnostics` の `DispatchSource` 圧迫イベントは `MemoryPressureMonitor.handle(level:)` に流すだけ。中枢が (1) 圧迫フラグ設定（自動解除）、(2) **登録された解放ハンドラ**の呼び出し、(3) 診断ログ追記（レベル/footprint/端末RAM）、(4) Developer Options 用の履歴/回数蓄積を行う。`MemoryImageCache` は `register(_:)` した解放ハンドラで **warning=上限半減（LRU 縮小）／critical=即時全消去** する（`ImageCacheKit` → `MosaicSupport` 依存）。履歴は `MemoryDebugSection` に表示（ADR-20）
- **CLIP モデルの扱い**: 同梱モデルは **OpenCLIP ViT-B-32/datacomp_xl（MIT）**。Core ML モデルと語彙は `MosaicPhotos/MobileCLIP/` に置き **`.gitignore` 対象**（サイズ）。`scripts/build_mobileclip.sh`（内部で `scripts/convert_clip.py`・open_clip→Core ML）で生成する。ファイル名は `MobileCLIP*`／config 名 `mobileclip_config.json` を互換のため据え置き（中身は OpenCLIP）。⚠️ 変換は**画像エンコーダを `compute_precision=FLOAT16`**（実機 ANE は fp16 前提）。**CLIP の mean/std 正規化は画像エンコーダ内に内包**し、ImageType は `scale=1/255` のままにする（アプリの入力経路を不変に保つ／旧 MobileCLIP は mean/std 無しだった点と異なる）。imageSize は config 経由（ViT-B-32 は 224）。モデルを変えたら `AutoAlbumSettingsKeys.perceptionVersion` を採番して全再埋め込み。fp16 は一部シミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落として安全に無効化する（**画像タワーの検証・本番は実機**。`ImageRecognitionTests` の画像系はシミュレータでスキップ）。未同梱でもアプリは動作し、CLIP 機能だけ無効化される。ランタイム（`MobileCLIPRuntime`）は `MobileCLIPKit` にあり `static let shared` で**遅延ロード**（起動を重くしない）。ロード結果は診断ログに残し、`MobileCLIP.modelsBundled` でロードせず同梱判定できる（Developer Options で可視化）。シミュレータは `.cpuOnly`、実機は `.all`
- **ピープル（顔クラスタ）＝オンデバイス顔認識**: 写真アプリの「ピープル」は**公開 PhotoKit API でアクセス不可**（旧 subtype-1000 方式は誤りで常に空＝撤去）。代わりに **Vision 顔検出（`VNDetectFaceRectanglesRequest`）＋同梱顔モデル（facenet InceptionResnetV1/VGGFace2・MIT・512次元L2正規化）で identity 埋め込み→逐次クラスタリング**で自前の「人物」を作る。ロジックは `AutoAlbumCore/Faces`（`FaceClustering`（純・コサイン逐次・テスト）/ `FaceStore`（@ModelActor・**別コンテナ "FacesV1"**＝CLIP データを壊さない）/ `FaceTagger`（背景スキャン・PhotoTagger と同じ譲り＋simulator スキップ）/ `PeopleEngine`（@MainActor @Observable ファサード）/ `PersonInfo`（表示値型）/ seam `FacePerceptionProvider`・`DetectedFaceSignal`）。実体（Vision+CoreML）は `MobileCLIPKit`（`FaceModelRuntime`・`FacePerceptionAdapter`）。モデルは `MosaicPhotos/FaceModel/`（**`.gitignore` 対象**・`scripts/build_facenet.sh`＋`convert_facenet.py` で生成・ImageType `scale=1/255`＋正規化内包・FLOAT16）。未同梱なら `isFaceModelAvailable==false` でセクション非表示。**端末写真は 640px・クラウド写真は Dropbox のキャッシュ済み 128px サムネ**で顔検出する（追加DL無し・クラウドは低解像度＝大きく写った顔中心・option B）。候補 refKey はアプリが列挙（`allImageRefKeys`＝PHAsset ＋ `dropboxStore.items`）。人物アルバム表示・代表顔アバターもクラウド対応（`PersonAlbumView`＝メンバー限定 MergedPhotoStore／`loadFaceAvatar` は `HeavyWorkScheduler.stores.dropboxStore` から取得）。クラスタしきい値はモデル依存（既定 0.45・実機調整）。アバターは代表顔の bbox を切り抜き
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
  - マスター（正本）: `docs/architecture-note/records/decisions.md`（設計判断＝ADR）/ `docs/architecture-note/records/case-studies.md`（事例・バグ・課題対応）。各ファイル冒頭の「運用ルール」と「テンプレート」に従う（ADR は `## ADR-N` 連番＋文脈/決定/結果、事例は症状/原因/対処/関連/残課題）。
  - HTML（`docs/architecture-note/design-decisions/adr.html` / `case-studies/*.html`）は MD からの**派生物**で、**指示に応じて取捨選択**して記載する（全件転記しない）。HTML 目次の定義は `docs/architecture-note/assets/nav.js` の `NAV` 配列が唯一の出典。
  - 順序: まず MD に追記（網羅）→ 必要なら HTML 化（選択）。撤回・変更時は MD の項を消さず状態を追記して経緯を残す。
