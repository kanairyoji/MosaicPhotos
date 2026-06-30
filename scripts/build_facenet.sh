#!/usr/bin/env bash
#
# 同梱する顔認識モデル（ピープルのクラスタリング用）を Core ML(.mlpackage) へ変換して配置する。
# ※ ローカルの Mac で実行（ネットDL・Python・coremltools が必要）。CLIP の build_mobileclip.sh と同流儀。
#
# 採用モデル: facenet-pytorch **InceptionResnetV1 / vggface2**（コード・重みとも MIT＝権利フリー）。
#   モバイル向けで精度も実用域。512 次元の L2 正規化埋め込み（コサイン＝内積）。
#
# 生成物（MosaicPhotos/FaceModel/ 配下＝PBXFileSystemSynchronizedRootGroup で自動取り込み・.gitignore 対象）:
#   FaceEmbedder.mlpackage   顔埋め込み（160x160 顔切り抜き・[0,1] 入力・正規化内包）
#   face_config.json         inputSize/embedDim/model（Swift が参照）
#
# 前提: macOS / Python 3.10+ / Xcode
# 使い方:  bash scripts/build_facenet.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.facenet_build"
OUT="$ROOT/MosaicPhotos/FaceModel"
VENV="$WORK/venv"

mkdir -p "$WORK" "$OUT"

echo "==> 1) Python 仮想環境"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 2) 依存をインストール（torch / coremltools / facenet-pytorch）"
pip install "torch>=2.1" "numpy<2" "coremltools>=8.0" "facenet-pytorch>=2.5" >/dev/null

echo "==> 3) Core ML へ変換"
python "$ROOT/scripts/convert_facenet.py" "$OUT"

echo "==> 完了。生成物:"
ls -la "$OUT"
echo
echo "次: Xcode で MosaicPhotos/FaceModel/ がターゲットに含まれることを確認してビルド。"
echo "    モデル未同梱でもアプリは動作し、ピープル（顔クラスタ）だけ無効化される。"
