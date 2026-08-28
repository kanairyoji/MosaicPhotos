# PhotosFeatureKit

このファイルは **Packages/PhotosFeatureKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/PhotosFeatureKit/         ← 写真機能の統合層（DropboxKit / LocalPhotoKit / PhotoSourceKit に依存）
  Sources/PhotosFeatureKit/
    MergedPhotoStore.swift         @MainActor @Observable。Local + Dropbox を統合する PhotoStore
    MergedPhotoItem.swift          ローカル/クラウドを束ねる PhotoItem（enum・id プレフィックスで衝突回避）
    PlaceScanner.swift             @MainActor @Observable。Local+Dropbox の位置情報を市区町村にグルーピング
  Tests/PhotosFeatureKitTests/     filter/state/MergedPhotoItem/placeScanSignature のテスト（iOS Sim）

```
