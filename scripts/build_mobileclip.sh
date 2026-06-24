#!/usr/bin/env bash
#
# MobileCLIP-S2 を Core ML（.mlpackage）に変換して、アプリに同梱する形で配置するスクリプト。
# ※ ローカルの Mac で実行してください（ネットDL・Python・coremltools が必要なため）。
#
# 生成物（MosaicPhotos/ 配下に置けば PBXFileSystemSynchronizedRootGroup で自動取り込み）:
#   MosaicPhotos/MobileCLIP/MobileCLIPImageS2.mlpackage   画像エンコーダ
#   MosaicPhotos/MobileCLIP/MobileCLIPTextS2.mlpackage    テキストエンコーダ
#   MosaicPhotos/MobileCLIP/bpe_simple_vocab_16e6.txt.gz  CLIP トークナイザ語彙
#   MosaicPhotos/MobileCLIP/mobileclip_config.json        入力サイズ・次元など（Swift 側が参照）
#
# 前提: macOS / Python 3.10+ / 空き容量 ~3GB / Xcode
# 使い方:  bash scripts/build_mobileclip.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.mobileclip_build"
OUT="$ROOT/MosaicPhotos/MobileCLIP"
VENV="$WORK/venv"
CKPT="$WORK/checkpoints/mobileclip_s2.pt"
VOCAB_URL="https://github.com/mlfoundations/open_clip/raw/main/src/open_clip/bpe_simple_vocab_16e6.txt.gz"
CKPT_URL="https://docs-assets.developer.apple.com/ml-research/datasets/mobileclip/mobileclip_s2.pt"

mkdir -p "$WORK/checkpoints" "$OUT"

echo "==> 1) Python 仮想環境を作成"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 2) 依存をインストール（torch / coremltools / mobileclip）"
pip install "torch>=2.1" numpy "coremltools>=8.0" >/dev/null
pip install "git+https://github.com/apple/ml-mobileclip.git" >/dev/null

echo "==> 3) チェックポイントを取得（MobileCLIP-S2）"
if [ ! -f "$CKPT" ]; then
  curl -fL "$CKPT_URL" -o "$CKPT"
fi

echo "==> 4) CLIP トークナイザ語彙を取得（Swift が読めるよう解凍して .txt で配置）"
curl -fL "$VOCAB_URL" -o "$WORK/bpe_simple_vocab_16e6.txt.gz"
gunzip -c "$WORK/bpe_simple_vocab_16e6.txt.gz" > "$OUT/bpe_simple_vocab_16e6.txt"

echo "==> 5) Core ML へ変換"
CKPT="$CKPT" OUT="$OUT" python "$ROOT/scripts/convert_mobileclip.py"

echo ""
echo "✅ 完了: $OUT に .mlpackage / 語彙 / config を出力しました。"
echo "   次の手順:"
echo "   1) Xcode で MosaicPhotos/MobileCLIP/ が「Copy Bundle Resources」に入っているか確認"
echo "      （PBXFileSystemSynchronizedRootGroup で自動取り込みのはず）"
echo "   2) アシスタント（Claude）に「モデルを置いた」と伝えると、Swift 側"
echo "      （MobileCLIPTextEmbedder の英訳→トークナイズ→推論、画像エンコーダ配線）を実装します。"
