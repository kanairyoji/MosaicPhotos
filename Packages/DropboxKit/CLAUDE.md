# DropboxKit

このファイルは **Packages/DropboxKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
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

```
