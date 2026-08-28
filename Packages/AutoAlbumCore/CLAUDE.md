# AutoAlbumCore

このファイルは **Packages/AutoAlbumCore/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/AutoAlbumCore/            ← 自動アルバム＋オンデバイス AI のロジック層（SwiftUI 非依存・MosaicSupport に依存）
  Sources/AutoAlbumCore/
    AutoAlbumEngine.swift          @MainActor @Observable ファサード。生成/AI/フォルダ/タグ付けを協調
    PhotoRef.swift                 "L-…"/"C-…" のエンコード（ローカル/クラウド統一キー・純）
    EnrichedPhoto.swift / BackgroundProcessing.swift  付加情報の値型 / 背景処理の重さプリセット（純）
    Models/                        PhotoEnrichment(@Model・メタデータのみ) / PhotoEmbedding(@Model・CLIP埋め込みを
                                   Float16 で別テーブル化) / GeneratedAlbum(@Model)
    Store/                         AutoAlbumStore(@ModelActor・SwiftData。埋め込み/アルバム永続化)
    Perception/                    PhotoPerceptionProvider / TextEmbedder / QueryTranslator / LabelProvider
                                   （seam・実体はアプリ側）/ PhotoTagger(背景 CLIP 埋め込み・スロットル) / PhotoEnricher
    AIAlbum/                       AIAlbumService（解釈永続化・増分/フル再評価・証拠ゲート・審査）/
                                   AIAlbumSearcher（タグ一致＋CLIP対比＋字句の RRF 融合）/ AlbumVerifier(FM審査) /
                                   AIAlbumInterpretationStore(解釈の永続化・版管理) / QuerySpecSanitizer(防御的接地) /
                                   JapaneseVisualLexicon(決定的視覚語/人物否定) / ClipMath(vDSP コサイン) /
                                   LexicalSearch(地名/人物) / RelativeDateParser(日英・日付の唯一の出典) /
                                   QueryUnderstanding(RuleBased) / FoundationModelsQueryUnderstanding(iOS26)
    Tags/                          TagStore(@ModelActor・TagsV1 別コンテナ・シーンタグ) /
                                   TagTagger(夜間トリクル付与)
    Strategies/                    TimePlaceStrategy(旅行抽出) / PathAlbumStrategy(フォルダ名) / CoverSelection 他
  Tests/AutoAlbumCoreTests/        search/lexical/clipmath/strategy/path/background のテスト（macOS）

```
