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
    BackupLayout.swift             Dropbox の配置（`<root>/<端末>/Backup` と `Share`・ADR-175）。パスを組む場所はここだけ
    BackupEngine.swift             @MainActor @Observable。バックアップのオーケストレーション
    DropboxBackupUploader.swift    写真/metadata の HTTP アップロード（認証・SwiftData から独立・テスト対象）
    BackupAssetReader.swift        PHAsset 本体データの取得（編集済みは fullSizePhoto＝今の見た目）
    BackupRenditionNaming.swift    どのレンディションを上げるか＋名前づけの純ロジック（ADR-168・テスト対象）
    BackupIndexing.swift           People/Album インデックス構築（top-level・Task.detached 用）
    BackupPlanning.swift           アップロード差分算出・エラー要約の純ロジック（テスト対象）
    BackupMetadataPlanning.swift   メタデータ v2（カタログ＋撮影月シャード・ADR-38）の分割/マージ純ロジック
    BackupMetadataStore.swift      **メタデータ v2 の唯一の書き手**（ADR-200）。`root` を持ち、
                                   シャードを書いたら必ずカタログへ登録する。印の書き先を
                                   パスから推測しない。バックアップもオフロードもここを通る
    PendingMetadataStore.swift     再送キュー（本体 JSON ＋ 追記ジャーナル）。消費口は `takeAll` の
                                   1 つだけ（追記と同じ錠の下・ADR-200）
    BackupSettingsKeys.swift / BackupDestination.swift  設定キー / 値オブジェクト
    BackupSettingsView.swift       バックアップ通常設定ビュー（#if canImport(UIKit)）
    BackupDebugSection.swift       Developer Options 向け詳細診断セクション（進捗/フォルダ確認/統計/ログ・public）
    BackgroundUpload/              夜間の背景アップロード（ADR-181・fire-and-forget）
      UploadSpool.swift              投入の意図＋本体のファイル台帳（`Caches/BackupSpool`）・`BackgroundUploadPolicy`（積む上限）
      BackgroundUploadSession.swift  背景 URLSession（identifier 固定・遅延生成）。応答の分類 `classify` / 投入の振り分け `split` は純ロジック
      BackupRunner+BackgroundUpload.swift  runner の spool 経路（`spoolOne` / `flushSpool` / `backgroundPlan`＝転送中は対象外・409 は前面へ）
      BackupEngine+Settle.swift      応答 → ジャーナル → 記録（`BackgroundSettlement.perform` で順序を固定）
    Share/                         家族共有（ADR-112/166/183）
      ShareSyncEngine.swift          @MainActor @Observable。セット CRUD・作成元追従（`refreshAllFromSource`）
      ShareSyncEngine+Sync.swift     反映本体（共有ルートの再帰一覧 1 回 → copy_batch/delete_batch → シャードの差分同期）。`RemoteShareIndex` / `ShareAnalysisPlanning`（純ロジック）
      ShareAnalysisData.swift             解析データの形式（content_hash キー・`shard-<xx>.json`・防御的検証）
      ShareAnalysisFetch.swift        受信側の取得（家族フォルダの再帰一覧 1 回・rev 差分）＋
                                      `accountAnalysisRoots`＝同じ Dropbox の他端末の `Analysis` 発見（ADR-222）
      AnalysisPublishPlanning.swift   解析の公開（ADR-222）の純ロジック。変わったシャードだけ・
                                      続きから一巡・指紋（FNV-1a）。**JSON は `.sortedKeys` で書く**
                                      （辞書の順序が揺れると毎回全部を上げ直す）
      AnalysisPublisher.swift         公開の本体（設定チェック → 解析を 2,000 枚ずつ集める →
                                      シャード → 計画 → アップロード/掃除 → 指紋と続きを保存）
      SharePlanning.swift / ShareImportPlanning.swift  コピー計画 / 受信側の突合（純ロジック）
    BackupLogger.swift             内部ロガー（MosaicSupport の LogChannel に委譲）
    BackupAlbumInfo.swift / BackupAssetRecord.swift  値オブジェクト / @Model
  Tests/BackupKitTests/            BackupPlanning / DropboxBackupUploader のテスト（macOS）

```
