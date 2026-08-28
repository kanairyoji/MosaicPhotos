# DropboxCore

このファイルは **Packages/DropboxCore/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
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

```
