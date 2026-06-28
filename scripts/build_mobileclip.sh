#!/usr/bin/env bash
#
# 同梱する画像/テキスト CLIP モデルを Core ML(.mlpackage) へ変換して配置するスクリプト。
# ※ ローカルの Mac で実行（ネットDL・Python・coremltools が必要）。
#
# 採用モデル: OpenCLIP **ViT-B-32 / datacomp_xl_s13b_b90k**（重み・コードとも MIT＝権利フリー）。
#   以前は MobileCLIP-S2 を使っていたが、その重みは Apple ML Research Model License
#   （研究目的限定・商用不可）で App Store 配布に使えないため、許容ライセンスの本モデルへ差し替えた。
#   ファイル名（MobileCLIP*.mlpackage 等）は互換のため据え置き（中身は OpenCLIP）。
#
# 生成物（MosaicPhotos/MobileCLIP/ 配下＝PBXFileSystemSynchronizedRootGroup で自動取り込み）:
#   MobileCLIPImageS2.mlpackage   画像エンコーダ（CLIP 正規化を内包・ImageType scale=1/255）
#   MobileCLIPTextS2.mlpackage    テキストエンコーダ
#   bpe_simple_vocab_16e6.txt     CLIP BPE トークナイザ語彙（OpenAI CLIP・MIT）
#   mobileclip_config.json        imageSize/contextLength/embedDim/model など（Swift が参照）
#
# 前提: macOS / Python 3.10+ / 空き容量 ~3GB / Xcode
# 使い方:  bash scripts/build_mobileclip.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.mobileclip_build"
OUT="$ROOT/MosaicPhotos/MobileCLIP"
VENV="$WORK/venv"
VOCAB_URL="https://github.com/mlfoundations/open_clip/raw/main/src/open_clip/bpe_simple_vocab_16e6.txt.gz"

# 採用モデル（変更したい場合はここを書き換える）
OC_MODEL="${OC_MODEL:-ViT-B-32}"
OC_PRETRAINED="${OC_PRETRAINED:-datacomp_xl_s13b_b90k}"

mkdir -p "$WORK" "$OUT"

echo "==> 1) Python 仮想環境"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 2) 依存をインストール（torch / coremltools / open_clip）"
pip install "torch>=2.1" numpy "coremltools>=8.0" "open_clip_torch>=2.24" >/dev/null

echo "==> 3) CLIP トークナイザ語彙を取得（解凍して .txt 配置）"
curl -fL "$VOCAB_URL" -o "$WORK/bpe_simple_vocab_16e6.txt.gz"
gunzip -c "$WORK/bpe_simple_vocab_16e6.txt.gz" > "$OUT/bpe_simple_vocab_16e6.txt"

echo "==> 4) Core ML へ変換（OpenCLIP $OC_MODEL / $OC_PRETRAINED）"
OC_MODEL="$OC_MODEL" OC_PRETRAINED="$OC_PRETRAINED" OUT="$OUT" CONTEXT=77 \
  python "$ROOT/scripts/convert_clip.py"

echo ""
echo "✅ 完了: $OUT に .mlpackage / 語彙 / config を出力しました（OpenCLIP $OC_MODEL/$OC_PRETRAINED・MIT）。"
echo "   認識率の確認: scripts/eval_recognition.sh"
