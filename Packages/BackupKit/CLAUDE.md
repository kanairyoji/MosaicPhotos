# BackupKit

このファイルは **Packages/BackupKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/BackupKit/               ← 端末写真→Dropbox バックアップ（DropboxCore / MosaicSupport に依存）
  Sources/BackupKit/
    BackupEngine.swift             @MainActor @Observable。バックアップのオーケストレーション
    DropboxBackupUploader.swift    写真/metadata の HTTP アップロード（認証・SwiftData から独立・テスト対象）
    BackupAssetReader.swift        PHAsset 本体データの取得
    BackupIndexing.swift           People/Album インデックス構築（top-level・Task.detached 用）
    BackupPlanning.swift           アップロード差分算出・エラー要約の純ロジック（テスト対象）
    BackupMetadataPlanning.swift   メタデータ v2（カタログ＋撮影月シャード・ADR-38）の分割/マージ純ロジック
    BackupSettingsKeys.swift / BackupDestination.swift  設定キー / 値オブジェクト
    BackupSettingsView.swift       バックアップ通常設定ビュー（#if canImport(UIKit)）
    BackupDebugSection.swift       Developer Options 向け詳細診断セクション（進捗/フォルダ確認/統計/ログ・public）
    BackupLogger.swift             内部ロガー（MosaicSupport の LogChannel に委譲）
    BackupAlbumInfo.swift / BackupAssetRecord.swift  値オブジェクト / @Model
  Tests/BackupKitTests/            BackupPlanning / DropboxBackupUploader のテスト（macOS）

```
