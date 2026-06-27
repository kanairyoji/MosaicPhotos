#!/usr/bin/env bash
#
# 画像認識（CLIP）の認識率を測る手動実行専用ツール。
# ⚠️ ユニットテスト/CI とは完全に分離。ビルドでは動かない。指示したときだけ実行する。
#
# 何をするか:
#   1) Imagenette（ImageNet 自由配布サブセット・10クラス・160px）を取得（初回のみ）
#   2) 出荷する Core ML モデル（MosaicPhotos/MobileCLIP/*.mlpackage）を coremltools で実行
#   3) zero-shot top-1 認識率を「X/100」で表示
#
# 前提: scripts/build_mobileclip.sh を一度実行して venv とモデルがある状態。
# 使い方:
#   scripts/eval_recognition.sh                  # 各クラス10枚=100枚
#   PER_CLASS=20 scripts/eval_recognition.sh     # 各クラス20枚=200枚
#   scripts/eval_recognition.sh --compute-units ALL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.mobileclip_build"
VENV="$WORK/venv"
DATA="$WORK/imagenette"
MODEL="$ROOT/MosaicPhotos/MobileCLIP"
URL="https://s3.amazonaws.com/fast-ai-imageclas/imagenette2-160.tgz"

[ -d "$VENV" ] || { echo "❌ venv が無い。先に bash scripts/build_mobileclip.sh を実行してください。"; exit 1; }
[ -d "$MODEL/MobileCLIPImageS2.mlpackage" ] || { echo "❌ モデルが無い。先に bash scripts/build_mobileclip.sh を実行してください。"; exit 1; }

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -q pillow >/dev/null 2>&1 || true

mkdir -p "$DATA"
if [ ! -d "$DATA/imagenette2-160/val" ]; then
  echo "==> Imagenette(160px) を取得（初回のみ・約98MB）"
  curl -fL "$URL" -o "$DATA/imagenette2-160.tgz"
  tar -xzf "$DATA/imagenette2-160.tgz" -C "$DATA"
fi

python "$ROOT/scripts/eval_recognition.py" \
  --model-dir "$MODEL" \
  --images-dir "$DATA/imagenette2-160/val" \
  --per-class "${PER_CLASS:-10}" \
  "$@"
