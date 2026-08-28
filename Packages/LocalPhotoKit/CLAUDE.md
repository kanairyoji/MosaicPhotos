# LocalPhotoKit

このファイルは **Packages/LocalPhotoKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/LocalPhotoKit/            ← 端末写真の UI 層（LocalPhotoCore / PhotoSourceKit に依存）
  Sources/LocalPhotoKit/
    LocalPhotoCore.swift           @_exported import LocalPhotoCore（再エクスポート）
    LocalPhotoContentView.swift    「写真」タブルートビュー
    LocalPhotoSettingsView.swift   端末写真ソース設定ビュー（キャッシュ上限）
    LocalThumbnailView.swift       PHAsset サムネイルセル
    LocalPhotoPageView.swift       PHAsset フルスクリーンページングビュー

```
