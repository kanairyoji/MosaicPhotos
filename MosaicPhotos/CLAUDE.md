# MosaicPhotos

このファイルは **MosaicPhotos/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

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
  ※ 顔認識ロジックは Packages/FaceCore/（旧 AutoAlbumCore/Faces）へ分離・共通プリミティブは Packages/PerceptionCore/
  MobileCLIP/                      CLIP の Core ML モデル＋語彙（.gitignore 対象・scripts/build_mobileclip.sh で生成）
  FaceModel/                       顔認識モデル（.gitignore 対象・scripts/build_facenet.sh で生成）
  HeavyWorkScheduler.swift         BGProcessingTask（ロック中の夜間処理＝タグ/埋め込み/顔スキャン/生成）

```
