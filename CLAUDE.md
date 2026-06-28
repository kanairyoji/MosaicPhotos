# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**MosaicPhotos** は iOS (iPhone) 向けの写真ビューワーアプリ。端末内の写真と Dropbox 上の写真を、ソース別（All / Photos / Cloud）・端末アルバム別・場所（市区町村）別に閲覧できる。外部 SDK は使用せず、すべて標準フレームワークで実装している。

加えて **オンデバイス AI** を持つ：自然文（任意言語）の **AI アルバム / 意味検索**を、語彙リストに縛られない **オープン語彙 CLIP（MobileCLIP・Core ML）** で実現する。クエリは Foundation Models で英語へ正規化（翻訳）し、端末・Dropbox 双方の写真の CLIP 埋め込みとコサイン類似で検索する。フル画像には表示専用の検出キーワードタグ（約300語に対する CLIP ゼロショット）を出す。OCR・固定語彙タグは持たない。通信なし・API キー不要。


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
| オンデバイス AI | **OpenCLIP ViT-B-32（DataComp・MIT＝権利フリー）**（Core ML・画像/テキスト埋め込み）でオープン語彙の意味検索 / 表示タグ（旧 MobileCLIP-S2 は重みが研究目的限定のため差し替え。ファイル名 `MobileCLIP*` は互換のため据え置き＝中身は OpenCLIP）。クエリ解釈・翻訳は Apple Foundation Models（`FoundationModels`）。ロジックは `AutoAlbumCore`、CLIP/翻訳ランタイム＋アプリ側 seam 実装は `MobileCLIPKit`（`AutoAlbumCore` に依存）に集約 |
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
  MobileCLIP/                      MobileCLIP の Core ML モデル＋語彙（.gitignore 対象・scripts/build_mobileclip.sh で生成）。
                                   ランタイム/seam 実装は Packages/MobileCLIPKit、ここはモデルバイナリのみ

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
                                   PlaceNameResolver(actor・CLGeocoder + 地名キャッシュ)
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
    AIAlbum/                       AIAlbumService / AIAlbumSearcher（構造化→意味(CLIP)＋字句の RRF 融合）/
                                   ClipMath(コサイン・FP32 Data 純) / SemanticRanker / LexicalSearch(地名/人物) /
                                   QueryUnderstanding(RuleBased) / FoundationModelsQueryUnderstanding(iOS26)
    Strategies/                    TimePlaceStrategy(旅行抽出) / PathAlbumStrategy(フォルダ名) / CoverSelection 他
  Tests/AutoAlbumCoreTests/        search/lexical/clipmath/strategy/path/background のテスト（macOS）

Packages/MobileCLIPKit/            ← CLIP/翻訳ランタイム＋AutoAlbumCore seam のアプリ側実装（AutoAlbumCore / MosaicSupport に依存）
  Sources/MobileCLIPKit/
    MobileCLIPRuntime.swift        MobileCLIP 画像/テキストエンコーダ（Core ML・遅延ロード static shared・ロード結果を診断ログへ）。
                                   MobileCLIP.modelsBundled でロード不要の同梱判定
    CLIPTokenizer.swift            BPE トークナイザ
    AIPerceptionAdapters.swift     PhotoPerceptionProvider（refKey→ローカル/クラウド画像→CLIP 埋め込み）/ MobileCLIPTextEmbedder
    AILanguageAdapters.swift       AppQueryTranslator（FM 英訳）/ loadLocalCGImage（共通画像ローダ）
    CLIPDisplayLabeler.swift       表示専用タグ：約300語に対する CLIP ゼロショット（保存済み clipVector を使用）
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
- **検索は語彙ゼロのオープン語彙 CLIP に一本化**: クエリ（任意言語）→ `QueryTranslator` で英語へ正規化 → `TextEmbedder`(CLIP) でテキスト埋め込み → 各写真 `clipVector` とコサイン（`SemanticRanker`）。これに構造化条件と字句（地名/人物のみ・`LexicalSearch`）を RRF 融合（`AIAlbumSearcher`）。**固定語彙リスト・OCR は持たない**。クラウド写真もサムネイルから CLIP 埋め込みして検索対象にする。構造化条件は**合成可能な `QuerySpec`**（DNF：節の OR・節内 AND・各条件 NOT・日付/場所/人物/人数/ソース/お気に入り/スクショ/向き/位置）で表し、ハードは `QueryEvaluator`、内容語は CLIP でソフト採点。相対日付は `RelativeDateParser`（日英）。Foundation Models が `GeneratedSpec`（OR 可）を、非対応端末は RuleBased（単一節）を出す（`interpretSpec`）。旧フラット `AIAlbumQuery` は後方互換で残し `asQuerySpec()` で橋渡し
- **知覚 seam はプロトコル＋`MobileCLIPKit` 実装**: `PhotoPerceptionProvider`(refKey→CLIP 埋め込み・ローカル/クラウド両対応) / `TextEmbedder` / `QueryTranslator`(Foundation Models) / `LabelProvider`(表示タグ) は `AutoAlbumCore` のプロトコルで、実体は `MobileCLIPKit`（`AIPerceptionAdapters` / `AILanguageAdapters` / `CLIPDisplayLabeler`）が `MobileCLIPRuntime`・`FoundationModels` で実装する。アプリの `AutoAlbumAdapters`（Composition Root）が `AutoAlbumEngine` の seam に注入する。`PhotoSourceKit` は `AutoAlbumCore` に依存せず、フル画像の付加情報は `photoInsight` 環境クロージャ経由で受け取る（レイヤー分離）
- **表示タグは表示専用（検索と分離）**: フル画像のキーワードタグは `CLIPDisplayLabeler`（約300語の英語キーワードに対する CLIP ゼロショット・保存済み `clipVector` を使用）で生成する。これは表示専用で**検索は語彙ゼロのまま**縛らない。`nonisolated` で概念埋め込みを一括構築（メイン外・キャッシュ）
- **背景 CLIP 埋め込みのスロットリング**: `PhotoTagger.embedUnprocessed` は小バッチ＋バッチ間スリープ＋`.background` QoS で trickle 実行する。重さは `BackgroundProcessing.presets`（段階）で設定可能（`AutoAlbumSettingsView`・キーは `AutoAlbumSettingsKeys.backgroundProcessingLevel`）。各段は名称＋パラメータ（件数/休止秒）を UI に提示する。`shouldPause` でユーザー操作中（スクラブ）と **メモリ圧迫中（`MosaicSupport.MemoryPressureMonitor.isUnderPressure`）** は処理を譲る（`Diagnostics` のメモリ圧迫ソースが warning/critical でフラグを立て、一定時間後に自動解除）
- **CLIP モデルの扱い**: 同梱モデルは **OpenCLIP ViT-B-32/datacomp_xl（MIT）**。Core ML モデルと語彙は `MosaicPhotos/MobileCLIP/` に置き **`.gitignore` 対象**（サイズ）。`scripts/build_mobileclip.sh`（内部で `scripts/convert_clip.py`・open_clip→Core ML）で生成する。ファイル名は `MobileCLIP*`／config 名 `mobileclip_config.json` を互換のため据え置き（中身は OpenCLIP）。⚠️ 変換は**画像エンコーダを `compute_precision=FLOAT16`**（実機 ANE は fp16 前提）。**CLIP の mean/std 正規化は画像エンコーダ内に内包**し、ImageType は `scale=1/255` のままにする（アプリの入力経路を不変に保つ／旧 MobileCLIP は mean/std 無しだった点と異なる）。imageSize は config 経由（ViT-B-32 は 224）。モデルを変えたら `AutoAlbumSettingsKeys.perceptionVersion` を採番して全再埋め込み。fp16 は一部シミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落として安全に無効化する（**画像タワーの検証・本番は実機**。`ImageRecognitionTests` の画像系はシミュレータでスキップ）。未同梱でもアプリは動作し、CLIP 機能だけ無効化される。ランタイム（`MobileCLIPRuntime`）は `MobileCLIPKit` にあり `static let shared` で**遅延ロード**（起動を重くしない）。ロード結果は診断ログに残し、`MobileCLIP.modelsBundled` でロードせず同梱判定できる（Developer Options で可視化）。シミュレータは `.cpuOnly`、実機は `.all`
- **端末診断（Diagnostics）**: 実機で Mac/Console なしに不具合を追えるよう、`MosaicSupport.Diagnostics.install()`（アプリ `init()` で呼ぶ）が未捕捉 ObjC 例外（`NSSetUncaughtExceptionHandler`）とメモリ圧迫（`DispatchSource`）を `Caches/diagnostics.log` へ記録する。`LogChannel` の `error` は Release でも、`info`/`verbose` は DEBUG のみ同ログへ転記。Developer Options の `DiagnosticsLogView` で閲覧・共有・クリアできる。※ Swift の `fatalError`/SwiftData trap はこのハンドラを通らない（標準クラッシュログ側）
- **DropboxKit のキャッシュ機構**: `DropboxPhotoStore` は `DropboxCacheStore`（`actor`）を介してファイル一覧・サムネイル・本体画像をキャッシュする。メタデータは SwiftData（`CachedDropboxItem` / `DropboxSyncState` / `CacheUsageEntry`）、バイナリは `ImageCacheKit` の `MemoryImageCache` + `DiskImageStore` で `Caches/DropboxKit/{thumbnails,fullimages}/` 配下にハッシュ化ファイル名（`DropboxCacheNaming`）で保存する。`contentHash` 変更検知による無効化と、`CacheUsageEntry`（最終アクセス日時）ベースの LRU 容量管理を行う
- **画像キャッシュの共通化（ImageCacheKit）**: メモリ（`MemoryImageCache`）+ ディスク I/O（`DiskImageStore`）のプリミティブは `ImageCacheKit` に集約し、`LocalPhotoCore`（`ThumbnailCache`）と `DropboxCore`（`DropboxCacheStore`・SwiftData LRU）の双方が利用する。**破棄ポリシー（LRU）は各利用側が持つ**（`DiskImageStore` 自体は持たない）。`DiskImageStore` のコアは Foundation のみで macOS テスト可能、`UIImage` 便宜メソッドのみ `#if canImport(UIKit)` 拡張
- **ロギングの共通化（MosaicSupport）**: `os.log` + `print` + DEBUG ゲートのパターンは `MosaicSupport` の `LogChannel`（subsystem / ラベルを引数化）に集約する。各パッケージのロガー（`DropboxLogger` / `BackupLogger`）は `LogChannel` への薄い委譲とし、`verbose` / `info` は DEBUG のみ、`error` は常に記録する
- **テスト用 seam（DI）**: 外部依存はプロトコルで抽象化しデフォルト引数で本番実装を注入する。`HTTPClient`（URLSession）/ `DateProvider`（時刻）/ `AccessTokenProvider`（トークン）を `DropboxThumbnailBatcher` / `DropboxSyncEngine` / `DropboxAuthService` / `BackupEngine` へ注入。テストはスタブを渡す。新規にネットワーク/時刻/トークンへ依存するコードは `URLSession.shared` / `Date()` を直書きせずこれらを使う
- **Dropbox API リクエストの集約**: 認証ヘッダ付与・ステータス検証を伴う RPC / content ダウンロードは `DropboxAPIClient`（`rpc` / `contentDownload`）に集約する。longpoll（認証不要・専用タイムアウト）など特殊なものは `HTTPClient` を直接使う
- **設定キーの一元化**: `@AppStorage` / `UserDefaults` のキー文字列は各パッケージの専用 enum に集約する（`GridSettingsKeys` / `CacheSettingsKeys` / `DropboxCacheSettingsKeys`（サムネ並列数 `thumbnailConcurrency` を含む）/ `BackupSettingsKeys` / `AutoAlbumSettingsKeys`（生成/知覚バージョン・背景処理段階など）/ アプリ層は `AppSettingsKeys`）。文字列リテラルを読み手・書き手に重複させない
- **写真ソースインターフェイスの統一**: `LocalPhotoCore` / `DropboxCore` / `PhotosFeatureKit` のストアは、操作・表示インターフェイス（一覧取得・状態管理・サムネイル/フル画像取得・グリッド/詳細表示）を `PhotoSourceKit` の `PhotoItem` / `PhotoLoadState` / `PhotoStore` プロトコルと汎用ビューに統一する。アイテム単位のローディング（thumbnail/fullImage/prefetch/location/metadata）は `PhotoLoading` プロトコルに分離し、`PhotoStore: PhotoLoading` として精緻化している（`Store: PhotoStore` 制約だけで両方のメソッドを利用できる）。`init` の設定パラメータ（`DropboxAuthService` 等）は各パッケージ固有のまま維持する
- **Dropbox API キーの一元管理**: `appKey` と `redirectURI` はアプリターゲットの `MosaicPhotos/DropboxConfig.swift`（`enum DropboxConfig`）に定義する。`DropboxCore` には設定値を持たせず、`HomeView` がここを参照して `DropboxAuthService.init(appKey:redirectURI:)` に渡す

- **UI 言語 / 国際化（i18n）**: ユーザー向け文字列の **base（原文）は英語**で記述する（日本語をハードコードしない）。国際化は **String Catalog（`.xcstrings`）** で行う（base=英語、追加言語＝日本語ほか・機械翻訳）。方式は **per-package（案A）**：各 UI パッケージは `Package.swift` に `defaultLocalization: "en"` ＋ `resources: [.process("Localizable.xcstrings")]` を宣言し（**SwiftPM CLI は `.xcstrings` を自動認識しないため明示必須**。無いと `Bundle.module` 不生成で `swift test` が落ちる）、パッケージ内 UI 文字列は小ヘルパー **`L(_:)`**（＝`String(localized:bundle:.module)`）で包む（`Text`/`Label`/`Button`/`Section`/`navigationTitle` 等は `String` を verbatim 表示するため一様に効く。`Text("x")` 直書きは既定で `Bundle.main` を見るため不可）。**アプリ本体**は `Text("x")` リテラルが `Bundle.main` を見るのでコード改変不要、`MosaicPhotos/Localizable.xcstrings` ＋ `project.pbxproj` の `knownRegions` に言語追加。**Developer Options/Debug は対象外（英語のまま）**。動的 String（`Text(変数)` は verbatim＝未翻訳）は `LocalizedStringResource`/`String(localized:)` 化が必要。日付/数値/地名はロケール対応の API を使う（ADR-17）
- **文字コード**: ソースコード・API リクエスト/レスポンスボディ・Keychain 保存値はすべて UTF-8 を使用する。Swift の `String` / `Data` デフォルト（`.utf8`）を維持し、他のエンコーディングを混在させない
- **開発者向けドキュメント**: コメント・コミットメッセージは日本語で構わない

- **設計判断・事例の記録（必須・マスターは Markdown）**: 設計上の判断、埋め込んだバグ、原因が非自明だった不具合、性能/メモリ/起動などの大きめの課題対応を行ったら、**必ず** Markdown のマスターに 1 項追記して網羅する。これらの記録はチャット履歴に頼らず、リポジトリ内に確実に残す。
  - マスター（正本）: `docs/architecture-note/records/decisions.md`（設計判断＝ADR）/ `docs/architecture-note/records/case-studies.md`（事例・バグ・課題対応）。各ファイル冒頭の「運用ルール」と「テンプレート」に従う（ADR は `## ADR-N` 連番＋文脈/決定/結果、事例は症状/原因/対処/関連/残課題）。
  - HTML（`docs/architecture-note/design-decisions/adr.html` / `case-studies/*.html`）は MD からの**派生物**で、**指示に応じて取捨選択**して記載する（全件転記しない）。HTML 目次の定義は `docs/architecture-note/assets/nav.js` の `NAV` 配列が唯一の出典。
  - 順序: まず MD に追記（網羅）→ 必要なら HTML 化（選択）。撤回・変更時は MD の項を消さず状態を追記して経緯を残す。
