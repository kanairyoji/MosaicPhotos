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

## 3. SmolVLM の量子化（視覚のみ INT8）と GIT-base 比較（2026-07）

Florence 撤回後、SmolVLM-256M を「軽く」する策と、より軽い代替（GIT-base）を実測比較した。

### 結果（Core ML サイズ・Mac CPU 速度・PyTorch 品質）

| 構成 | サイズ | 速度(1枚) | メモリ(PyTorch RSS) | 品質 |
|---|---|---|---|---|
| SmolVLM fp16（原本） | 491MB（V179+D258+embed54） | ~3.3秒 | 1887MB | 詳細（7〜29語） |
| SmolVLM 両方 INT8 | 287MB | ~3.3秒（CPU同速） | — | **劣化リスク大** |
| **SmolVLM 視覚のみ INT8**（採用） | **402MB**（V90+D258+embed54） | ~3.3秒 | — | **維持** |
| GIT-base（microsoft・MIT） | ~350MB見込み | ~0.5秒（5〜6倍速） | 1025MB | 短文・幻覚多（"pay phone"等） |

### 重要な発見: 量子化への強さは部品で正反対
- **視覚エンコーダ（VLMVision）は INT8 に強い**: 出力は連続ベクトル（画像埋め込み）。fp16 と INT8 の **cos≈0.999**（実測 0.9988/0.9983）＝実質無害。
- **言語デコーダ（VLMDecoder）は INT8 に弱い**: 49,280 語から次単語を argmax で選ぶ離散決定なので、丸めで単語が入れ替わる。fp16 と INT8 の**次単語 argmax 一致率 26%**＝キャプションが崩れる。
- → **視覚だけ INT8・デコーダは fp16 のまま**が最適（採用）。削減は ~90MB（491→402MB・約18%）と小さいが、品質を保ったまま安全に軽量化。大きく縮めるにはデコーダを 4bit＋per-channel＋キャリブレーション等で丁寧に量子化する必要（要検証）。
- GIT-base は 5〜6倍速・軽量でアーキも ANE 安全寄り（画像前置＋自己注意）だが、COCO 学習で**短く誤りが多い**ため不採用。

### 再現手順
```bash
bash scripts/build_smolvlm.sh                    # 視覚のみ INT8 量子化は既定 ON
QUANTIZE_VISION=none bash scripts/build_smolvlm.sh  # 視覚も fp16 のまま（原本）にするとき
```

### 追記: より高品質な VLM の比較 → SmolVLM-500M 採用（ADR-34・2026-07）

decoder-only(ANE安全) 縛りで、256M より良い候補を実測（`bench_vlm_quality.py`・Mac fp32 MPS・同一4画像）。

| モデル | params | 速度/枚 | 品質 | ライセンス |
|---|---|---|---|---|
| SmolVLM-256M（現行→旧） | 256M | ~3.4秒 | 曖昧（物体誤認・"文字がある板"） | Apache |
| **SmolVLM-500M（採用）** | 507M | ~3.8秒 | **良（物体正確・看板 "Please Prepay" を読む）** | Apache |
| SmolVLM2-500M | ~500M | ~4.1秒 | 良（同等・画像は v1 が素直） | Apache |
| FastVLM-0.5B | 623M | **~2.1秒（最速）** | 良（詳細・看板読む） | **apple-amlr（研究のみ＝不採用）** |

- **FastVLM は最速・高品質だが `apple-amlr`（Apple ML Research License）で製品同梱不可**＝性能以前に不採用（MobileCLIP-S2 と同じ理由）。
- **SmolVLM-500M を採用**（Apache・ANE安全確実・256M より明確に高品質）。Core ML **877MB**（デコーダ 691MB fp16・視覚 INT8 94MB・埋込 90MB）＝256M(402MB) の約2.2倍でメモリが律速。デコーダは INT8 に弱いので fp16 据え置き。
- 重い文章生成なので **キャプションはお気に入り限定**に絞る（ADR-34）。

---

## 4. 自然文検索の品質ベースライン（SearchQualityTests・2026-07）

エージェント型検索（ReACT 2フェーズ・検討中）に着手する前に、**現行パイプラインの検索品質を数値化**する
回帰ハーネスを整備し、ベースラインを計測した。

### 方法
- ハーネス: `MosaicPhotosTests/SearchQualityTests`（手動実行・フィクスチャ無し環境ではスキップ）。
  **本番と同じ検索パイプライン**（決定的プレビュー解釈 → タグ＋CLIP＋字句の RRF 融合＋ハード条件）を
  実物のテキストタワー/トークナイザで回す。画像埋め込みは `scripts/gen_eval_fixture.py` が Mac で前計算
  （シミュレータの画像タワーは fp16 NaN のため）。
- データ: Imagenette 10クラス×20枚＝200枚。日付（クラスごとの月）・場所・人物（木村太郎/花子）を合成。
- クエリ: `scripts/eval_queries.json` 28問（英語直接/英語言い換え/日本語レキシコン内/日本語自由文/
  ハード条件/複合）。翻訳（夜間FM相当）は `en` 欄、場所解釈は `place` ヒントで決定的に代替。
  FM の解釈・審査はテスト環境で不可＝**ベースラインは審査（AlbumVerifier）前の検索品質**。
- 指標: R@20（プール順位の上位20に正解20枚が何割入るか）/ memberP・memberR（採用メンバーの精度・再現率）。

### ベースライン結果（現行パイプライン）

| カテゴリ | n | R@20 | memberP | memberR |
|---|---|---|---|---|
| semantic-en（英語直接） | 3 | 0.95 | 0.94 | 0.92 |
| paraphrase-en（英語言い換え） | 10 | 0.93 | 1.00 | **0.61** |
| ja-lexicon（レキシコン内日本語） | 2 | 1.00 | 1.00 | 0.93 |
| ja-free（自由日本語・翻訳頼み） | 7 | 0.92 | 0.99 | **0.68** |
| hard（場所/人物条件） | 4 | (0.00)* | 1.00 | 1.00 |
| mixed（ハード＋意味） | 2 | 1.00 | 1.00 | 0.88 |
| **全体** | 28 | 0.81 | **0.99** | **0.76** |

\* hard は意味テキスト空＝プール無し（R@20 は定義上 0）。members は完全（ハード条件のみで確定）。

### 読み取り
- **精度は極めて高い**（memberP≈0.99）＝誤った写真はほぼ入らない。**弱点は再現率**：特に言い換え系
  （paraphrase-en 0.61 / ja-free 0.68）で、正解の3〜4割が semanticMargin（上位帯 0.06）の外に落ちる。
  柔軟な自然文対応の改善ターゲットは「**取りこぼしの回収**」（マルチプローブ・キャプションチャンネル・
  Phase 2 の unsure 再判定）と数値で確定した。
- **タグチャンネルはこのハーネスでは無効**（Vision classify がシミュレータ＋160px 画像で 0 タグ）。
  ベースラインは CLIP＋字句＋ハードのみの成績。実機ではタグが加わる分だけ上振れする。
- フィクスチャは 10 クラスの易しい分離。実ライブラリより甘い数値になるが、**相対比較（改良前後の回帰
  検出）には十分**。

### 再現手順
```bash
source .mobileclip_build/venv/bin/activate && python scripts/gen_eval_fixture.py
xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MosaicPhotosTests/SearchQualityTests
cat .mobileclip_build/eval/report.txt
```

### 追記: マルチプローブ導入の A/B（ADR-35・2026-07）

意味採点を「主フレーズのみ」→「主フレーズ＋FM 言い換えプローブ（最大4）の **max-over-probes**」に
変更した効果（同ハーネス・プローブはクエリ集の `probes` 欄＝FM `expandProbes` 出力の決定的代替）:

| 指標 | ベースライン | マルチプローブ | Δ |
|---|---|---|---|
| paraphrase-en memberR | 0.61 | **0.79** | **+0.18** |
| ja-free memberR | 0.68 | **0.85** | **+0.17** |
| 全体 memberR | 0.76 | **0.86** | **+0.10** |
| 全体 memberP | 0.99 | 0.96 | −0.03 |
| 全体 R@20 | 0.81 | 0.82 | +0.01 |

**狙いどおり弱点だった言い換え再現率が +17〜18pt**。精度の微減（−0.03）はプローブが拾う近縁写真で、
本番ではこの後段に LLM 審査（AlbumVerifier・ハーネス対象外）が入って刈られる。判断: 採用。

---

## 付記: 評価の限界と今後

- すべて Mac 実測で、**iPhone ANE の絶対値は別途実機計測が必要**（シミュレータは VLM をスキップする設計）。
- 精度は Imagenette×1000 クラス zero-shot の単一シード。差の大きい TinyCLIP(−14pt)・不変の INT8 の結論は頑健だが、
  本アプリの本質（**自然文→画像検索**）に近い **Recall@k 評価**（実写真＋自然文クエリ集合）を将来用意すると、
  CLIP 系の意思決定精度がさらに上がる。
- Florence は phase 2 で INT8 化（~230MB）や OCR/領域タスクの活用余地がある。
