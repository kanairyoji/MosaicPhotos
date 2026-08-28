# MosaicSupport

このファイルは **Packages/MosaicSupport/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/MosaicSupport/            ← 最下層 SPM パッケージ（横断ユーティリティ・依存なし）
  Sources/MosaicSupport/
    LogChannel.swift               os.log + print + DEBUG ゲートを集約した共通ロガー（各レベルを DiagnosticsLog にも転記）
    Diagnostics.swift              DiagnosticsLog（Caches/diagnostics.log へロールリング追記・閲覧/共有/クリア）/
                                   currentMemoryFootprintMB() / Diagnostics.install()（未捕捉例外＋メモリ圧迫を記録）
  ※ DropboxCore / BackupKit / MobileCLIPKit / アプリが依存。各パッケージのロガーは LogChannel に委譲する

```
