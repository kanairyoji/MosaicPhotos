# LocalPhotoCore

このファイルは **Packages/LocalPhotoCore/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
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

```
