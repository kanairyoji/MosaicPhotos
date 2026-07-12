# モデル比較・評価記録（オンデバイス AI）

オンデバイス AI で用いるモデルの選定・入れ替えにあたって行った**検証方法と実測結果**を集約する。
判断そのものは ADR（[decisions.md](decisions.md) の ADR-31 / ADR-32）に、ここには**再現可能な評価手順と数値**を残す。

> 運用ルール: 新しいモデル比較を行ったら、本ファイルに「目的／方法／条件／結果（表）／結論／再現手順」を 1 節追記する。
> 数値は実測値のみを載せ、外挿・推定は明示する。評価スクリプトは `scripts/` に手動実行専用ツールとして残す（CI とは独立）。

計測環境（共通・2026-07）: Apple Silicon Mac（darwin）／ coremltools 9.0 ／ open_clip 3.3.0 ／ torch 2.8 ／
transformers（CLIP 系 4.57 / Florence 4.49）。⚠️ **Mac 上の実測であり iPhone 実機の ANE 値ではない**。目的は
「候補どうしの相対比較」と「出荷経路（Core ML）で動く/速いことの確認」。絶対値は実機で別途確認する。

共通データセット: **Imagenette**（fast.ai・ImageNet の自由配布 10 クラスサブセット・160px val）。
`scripts/eval_recognition.sh` が初回に自動取得（`.mobileclip_build/imagenette/…`）。

---

## 1. CLIP 埋め込み（意味検索）の 3 構成比較 → INT8 採用（ADR-31）

### 目的
同梱 CLIP（OpenCLIP ViT-B-32/DataComp・fp16・289MB）を「似た精度でより軽く」する。現行／INT8 量子化／
TinyCLIP-40M の 3 構成を**出荷経路の Core ML で同一ハーネス**に通し、メモリ・精度・速度を比較する。

### 方法・条件
- ツール: `scripts/bench_clip.py`（手動実行専用）。各構成の Core ML `.mlpackage`（画像/テキストエンコーダ）を
  coremltools で実行。
- 精度: **zero-shot top-1**。判別力を出すため **1000 クラス**（`open_clip.IMAGENET_CLASSNAMES`）で識別
  （10 クラス識別だと飽和して差が出ないため）。Imagenette 200 枚（各クラス 20 枚・seed 固定）。
- 速度: 画像 1 枚 / テキスト 1 回の推論時間（ウォームアップ後の中央値）。
- メモリ: モデル実体サイズ（ディスク）＋ プロセス peak RSS。
- compute_units: `CPU_ONLY`（fp16 の数値安定性のため・3 構成で統一）。
- 量子化: `coremltools.optimize.coreml.linear_quantize_weights`（linear_symmetric・int8・weight_threshold=512）。
- TinyCLIP: HF の transformers CLIPModel 形式（`wkcn/TinyCLIP-ViT-40M-32-Text-19M-LAION400M`）を Core ML へ変換。

### 結果

| 構成 | サイズ(画像+テキスト) | 精度 top-1 | 画像1枚 | テキスト1回 | peak RSS |
|---|---|---|---|---|---|
| 現行 ViT-B-32 fp16 | 289MB (168+121) | 75.0% | 10.0ms | 7.2ms | 838MB |
| **INT8 量子化**（同一モデル） | **145MB (84+61)** | **76.0%** | 9.6ms | 7.0ms | 771MB |
| TinyCLIP-40M fp16 | 161MB (76+85) | 61.0% | 5.5ms | 3.6ms | 672MB |

補足検証（TinyCLIP の精度低下の切り分け）:
- ネイティブトークナイザ＋PyTorch fp32: **67.0%**（＝TinyCLIP 本来の実力。ImageNet 公称 66.6% と整合）。
- ネイティブトークナイザ＋Core ML fp16: **61.0%**（`matmul` に overflow/NaN 警告）。
- → 低下は**トークナイザ差ではなく fp16 変換の数値不安定**（TinyCLIP は蒸留・小型で fp16 に敏感）。ViT-B-32 は
  安定（nan=0）。

### 結論
**INT8 量子化を採用**。容量ほぼ半減（289→145MB）で精度は不変（75→76% は誤差）。TinyCLIP は −14pt と低下が
大きく、テキスト側の語彙埋め込み表で 161MB と INT8 より重く不採用。速度は意思決定の決め手にならない（85k 枚の
夜間索引で「約7分 vs 14分の純計算」程度・元々トリクル実行）。詳細は ADR-31。

### 再現手順
```bash
bash scripts/build_mobileclip.sh                 # 現行(既定 QUANTIZE=int8)を生成
QUANTIZE=none bash scripts/build_mobileclip.sh    # fp16 版が要るとき
# 3 構成を .clipbench/ 等に用意し、各 model-dir で:
python scripts/bench_clip.py --model-dir <dir> \
  --images-dir .mobileclip_build/imagenette/imagenette2-160/val \
  --per-class 20 --compute-units CPU_ONLY
```

---

## 2. VLM キャプションの SmolVLM vs Florence-2-base → Florence 採用（ADR-32）

### 目的
遅い SmolVLM-256M（実機 1〜2 秒/枚）を、より軽量・高速なモバイル向け VLM に置き換えたい（キャプション機能自体は
残す）。自然文キャプションの品質・速度・メモリで比較し、さらに**出荷経路の Core ML で動くか**を PoC で確認する。

### 方法・条件
- 品質・速度の一次比較: `scripts/bench_vlm.py`（HuggingFace transformers・**Mac PyTorch fp32 MPS**）。
  同一画像・生成上限 48 トークン・ウォームアップ後平均。⚠️ Core ML/ANE ではなく相対比較用。
- 出荷経路の確認: `scripts/convert_florence_poc.py`（Florence を Core ML fp16 化し、貪欲デコードで
  キャプション生成・所要時間を実測。compute_units=CPU_AND_NE）。
- 画像: Imagenette からゴミ収集車・ガソリンスタンドの 2 枚（自然文で内容が出るもの）。

### 結果 A: PyTorch 一次比較（bench_vlm.py・Mac MPS fp32）

| 指標 | SmolVLM-256M | Florence-2-base |
|---|---|---|
| パラメータ | 256.5M | 231.4M |
| 重みサイズ(HF cache) | 494MB | 444MB |
| ピーク RSS(fp32) | ~1795MB | ~1675MB |
| 自然文キャプション latency | **~4.0 秒** | **~0.85 秒**（詳細）/ ~0.5 秒（短文） |
| トークンあたり | 116〜187ms | 24〜97ms |

→ Florence が自然文キャプションで**約 4.7 倍速**（より詳しい文を出しても）。速さの理由は、SmolVLM が LLM
デコーダに 64 画像トークンを通す prefill が重い（≈3.5 秒の固定コスト）のに対し、Florence は軽量 seq2seq(BART系)
デコーダで prefill・デコードとも安いこと。

出力例（ガソリンスタンド）:
- SmolVLM: 「In this image we can see a machine, there is a board with some text on it, …」（漠然）
- Florence(DETAILED): 「The image shows a gas pump with a sign that reads "Please Prepay" …」（**看板文字=OCR も拾う**）

### 結果 B: Core ML 変換 PoC（convert_florence_poc.py・Mac CPU_AND_NE）

| 項目 | 実測 |
|---|---|
| 1枚あたり合計 | **約 410〜450ms**（エンコーダ ~150ms ＋ デコーダ 6〜7ms/token） |
| 対 SmolVLM（実機 1〜2 秒） | **約 3〜5 倍速**（PyTorch だけでなく Core ML でも速さが保たれる） |
| モデルサイズ(fp16 Core ML) | 442〜463MB（encoder ~258 ＋ decoder ~184）≒ SmolVLM 491MB |
| fp16 安定性 | NaN なし。詳細キャプション生成 OK。OCR（"Please Prepay"）も fp16 変換後に生存 |

出力例（Core ML fp16）: 「The image shows a gas pump with a sign that reads "Please Prepay" in the
foreground, and a wall in the background. …」（fp32 参照とは語尾が僅かに異なるが内容は同等）。

### 変換上の落とし穴（PoC で踏んで対処・量産版に反映）
1. **動的長デコーダは ANE 非対応**（"Data-dependent shapes were disabled"）→ 固定長 [1,MAXLEN] にパディングし
   現在位置の logits を読む（SmolVLM 時代と同方式）。
2. **task_ids は processor 経由で作る**必要。`proc.tokenizer("<DETAILED_CAPTION>")` の literal トークン化は
   タスク名をエコーする（Florence は task を自然文プロンプトへ展開する）。
3. **encoder(fp16)→decoder の dtype 一致**。デコーダ入力を fp16 にして vision 出力を直結（fp32 だと毎回 cast copy）。
4. Florence の remote code は **transformers 4.49** でしか変換できない（新しい版の生成ループと非互換・ランタイムは
   Core ML なので影響なし）。

### 結論
**Florence-2-base を採用**（MIT・HF モデルカードで確認）。同等以下のサイズ・メモリで自然文キャプションが 3〜5 倍速く、
内容は同等以上（OCR も滲む）。詳細は ADR-32。

### 再現手順
```bash
# 一次比較（PyTorch）: モデルごとに別プロセスで（peak RSS 分離のため）
python scripts/bench_vlm.py --model smolvlm  --device mps --runs 5 --image <img>
python scripts/bench_vlm.py --model florence --device mps --runs 5 --image <img>
# Core ML 変換 PoC（貪欲デコード＋所要時間）
python scripts/convert_florence_poc.py     # .vlmbench_flor/venv(transformers 4.49) で
# 量産変換（出荷資産の生成）
bash scripts/build_florence.sh
```

---

## 付記: 評価の限界と今後

- すべて Mac 実測で、**iPhone ANE の絶対値は別途実機計測が必要**（シミュレータは VLM をスキップする設計）。
- 精度は Imagenette×1000 クラス zero-shot の単一シード。差の大きい TinyCLIP(−14pt)・不変の INT8 の結論は頑健だが、
  本アプリの本質（**自然文→画像検索**）に近い **Recall@k 評価**（実写真＋自然文クエリ集合）を将来用意すると、
  CLIP 系の意思決定精度がさらに上がる。
- Florence は phase 2 で INT8 化（~230MB）や OCR/領域タスクの活用余地がある。
