#!/usr/bin/env bash
#
# 同梱する VLM（写真キャプション生成＝AI アルバムの精度向上・フル画像の「AI description」）を
# Florence-2-base で Core ML へ変換して配置する。build_smolvlm.sh の後継（ADR-32）。
# ※ ローカルの Mac で実行（ネットDL・Python・coremltools が必要）。
#
# 採用モデル: microsoft/Florence-2-base（MIT）。DaViT 視覚 + BART 系 encoder-decoder。
#   自然文キャプションが SmolVLM より約3〜5倍速く（実機 Core ML で ~0.4秒/枚）、内容は同等以上（OCR も滲む）。
#   タスクは <DETAILED_CAPTION> を焼き込み（1文〜数文の自然文説明）。
#
# ⚠️ transformers は 4.49 に固定（Florence の remote code が新しい版の生成ループと非互換なため。
#    ランタイムは Core ML なので transformers 版はビルド時のみ影響）。
#
# 生成物（MosaicPhotos/VLM/ 配下＝PBXFileSystemSynchronizedRootGroup で自動取り込み・.gitignore 対象）:
#   VLMVision.mlpackage    画像(ImageType scale=1/255・mean/std内包・768) → encoder_hidden + encoder_mask
#   VLMDecoder.mlpackage   decoder_input_ids[1,MAXLEN] + encoder_hidden + encoder_mask → logits
#   vlm_vocab.json / vlm_merges.txt   byte-level BPE（GPT2Tokenizer 互換・復号に使用）
#   vlm_config.json        task / maxLen / 特殊トークン ID 等（Swift が参照）
#   （SmolVLM の vlm_embed_tokens.bin は不要＝Florence デコーダはトークン ID を直接受ける）
#
# 前提: macOS / Python 3.9+ / 空きディスク ~3GB / ネットワーク（HF から ~1GB DL・アカウント不要）
# 使い方:  bash scripts/build_florence.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.vlmbench_flor"
OUT="$ROOT/MosaicPhotos/VLM"
VENV="$WORK/venv"

mkdir -p "$WORK" "$OUT"

echo "==> 1) Python 仮想環境"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 2) 依存をインストール（torch / transformers==4.49 固定 / coremltools / timm / einops）"
pip install "torch>=2.3" "numpy<2" "coremltools>=8.1" "transformers==4.49.0" \
    "timm" "einops" "accelerate" "pillow" >/dev/null

echo "==> 3) 既存 SmolVLM 生成物を退避（Florence が置き換える）"
rm -f "$OUT/vlm_embed_tokens.bin"

echo "==> 4) Core ML へ変換（DL 含め 20〜40 分・初回はモデル ~1GB をダウンロード）"
OUT="$OUT" python "$ROOT/scripts/convert_florence.py"

echo "==> 完了。生成物:"
ls -la "$OUT"
echo
echo "次: Xcode で MosaicPhotos/VLM/ がターゲットに含まれることを確認してビルド。"
echo "    モデル未同梱でもアプリは動作し、VLM キャプションだけ無効化される。"
