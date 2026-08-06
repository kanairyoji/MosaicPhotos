#!/usr/bin/env bash
#
# 同梱する顔認識モデルを AuraFace-v1 に差し替える（ADR-70）。build_facenet.sh と同流儀。
# ※ ローカルの Mac で実行（ネットDL・Python・coremltools が必要）。
#
# 採用モデル: fal/AuraFace-v1（Hugging Face・**Apache 2.0**＝商用可・学習データも商用可）。
#   ArcFace 系 ResNet100。AGEDB 96.10 ＝ 年齢差に強い（facenet の主弱点への直撃）。
#   512 次元埋め込み（ラッパで L2 正規化＝コサイン＝内積）。
#
# 生成物（MosaicPhotos/FaceModel/ 配下＝自動取り込み・.gitignore 対象）:
#   FaceEmbedder.mlpackage   顔埋め込み（112x112 ArcFace 5 点整列入力・正規化内包）
#   face_config.json         inputSize/embedDim/model/alignment/pipelineVersion
#
# facenet に戻すには: bash scripts/build_facenet.sh（上書きで戻る・再スキャンが走る）
#
# 前提: macOS / Python 3.10+ / Xcode
# 使い方:  bash scripts/build_auraface.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.auraface_build"
OUT="$ROOT/MosaicPhotos/FaceModel"
VENV="$WORK/venv"

mkdir -p "$WORK" "$OUT"

echo "==> 1) AuraFace-v1 の重みをダウンロード（初回のみ・約 260MB）"
ONNX="$WORK/glintr100.onnx"
if [ ! -f "$ONNX" ]; then
  curl -fL --retry 3 -o "$ONNX" \
    "https://huggingface.co/fal/AuraFace-v1/resolve/main/glintr100.onnx"
fi
ls -la "$ONNX"

echo "==> 2) Python 仮想環境"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 3) 依存をインストール（torch / coremltools / onnx2torch / onnxruntime）"
pip install "torch>=2.1" "numpy<2" "coremltools>=8.0" "onnx>=1.15" \
            "onnx2torch>=1.5" "onnxruntime>=1.17" >/dev/null

echo "==> 4) Core ML へ変換（検証込み）"
python "$ROOT/scripts/convert_auraface.py" "$WORK" "$OUT"

echo "==> 完了。生成物:"
ls -la "$OUT"
echo
echo "次: Xcode でビルド。パイプライン版 v5 のため初回起動で全再スキャンが走る"
echo "    （命名は写真の重なりで持ち越し・修正ジャーナルは保持）。"
