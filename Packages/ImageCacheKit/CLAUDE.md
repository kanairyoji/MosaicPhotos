# ImageCacheKit

このファイルは **Packages/ImageCacheKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/ImageCacheKit/            ← 画像キャッシュ共通プリミティブ・SwiftUI 非依存
  Sources/ImageCacheKit/
    MemoryImageCache.swift         NSCache ラッパー（メモリ層）
    DiskImageStore.swift           ディレクトリ単位のディスク I/O + LRU 列挙（コアは Foundation のみ）
  Tests/ImageCacheKitTests/        DiskImageStore の LRU/IO テスト（macOS）
  ※ LocalPhotoCore（ThumbnailCache）と DropboxCore（DropboxCacheStore）が共用。破棄ポリシーは各利用側が持つ

```
