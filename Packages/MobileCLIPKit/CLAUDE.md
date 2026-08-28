# MobileCLIPKit

このファイルは **Packages/MobileCLIPKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/MobileCLIPKit/            ← CLIP/翻訳ランタイム＋AutoAlbumCore seam のアプリ側実装（AutoAlbumCore / MosaicSupport に依存）
  Sources/MobileCLIPKit/
    MobileCLIPRuntime.swift        MobileCLIP 画像/テキストエンコーダ（Core ML・遅延ロード static shared・ロード結果を診断ログへ）。
                                   MobileCLIP.modelsBundled でロード不要の同梱判定
    CLIPTokenizer.swift            BPE トークナイザ
    AIPerceptionAdapters.swift     PhotoPerceptionProvider（refKey→ローカル/クラウド画像→CLIP 埋め込み）/ MobileCLIPTextEmbedder
    AILanguageAdapters.swift       AppQueryTranslator（FM 英訳）/ loadLocalCGImage（共通画像ローダ）
    CLIPDisplayLabeler.swift       表示タグ補完：約300語に対する CLIP ゼロショット（保存済み clipVector を使用）
    VisionTagAdapter.swift         シーンタグ（OS 内蔵 VNClassifyImageRequest・精度校正済み足切り）
  ※ アプリの AutoAlbumAdapters がこれらを AutoAlbumEngine の seam に注入する
```
