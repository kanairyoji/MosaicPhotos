#!/usr/bin/env bash
#
# ⚠️ 後継あり: 現行の VLM は Florence-2-base（scripts/build_florence.sh・ADR-32）。本スクリプトは
#    旧 SmolVLM 用で参考のため残置（Florence の方が 3〜5倍速く OCR も拾える）。新規は build_florence.sh を使う。
#
# 同梱する小型 VLM（写真キャプション生成＝AI アルバムの精度向上用）を Core ML へ変換して配置する。
# ※ ローカルの Mac で実行（ネットDL・Python・coremltools が必要）。build_facenet.sh と同流儀。
#
# 採用モデル: HuggingFaceTB/SmolVLM-500M-Instruct（Apache-2.0・高品質・ADR-34。SMOLVLM_MODEL で差替可）。
#   SigLIP 視覚エンコーダ + SmolLM2-135M デコーダ。写真 1 枚 → 短い英語キャプション。
#   夜間バッチ（電源＋アイドル/ロック中）で全写真に少しずつ付与する想定（数晩がかりで良い）。
#
# 生成物（MosaicPhotos/VLM/ 配下＝PBXFileSystemSynchronizedRootGroup で自動取り込み・.gitignore 対象）:
#   VLMVision.mlpackage    画像 → 画像トークン埋め込み（512x512・[0,1] 入力・正規化内包）
#   VLMDecoder.mlpackage   テキスト+画像埋め込み → next-token logits（固定長・KVキャッシュ無しの単純形）
#   vlm_embed_tokens.bin   トークン埋め込み行列（fp16・Swift 側でルックアップ）
#   vlm_vocab.json / vlm_merges.txt   GPT2 系 BPE の語彙・マージ（Swift 側トークナイザ用）
#   vlm_config.json        形状・特殊トークン ID・プロンプト雛形（Swift が参照）
#
# 前提: macOS / Python 3.10+ / 空きディスク ~3GB / ネットワーク（HF から ~1GB DL・アカウント不要）
# 使い方:  bash scripts/build_smolvlm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.smolvlm_build"
OUT="$ROOT/MosaicPhotos/VLM"
VENV="$WORK/venv"

mkdir -p "$WORK" "$OUT"

echo "==> 1) Python 仮想環境"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

echo "==> 2) 依存をインストール（torch / transformers / coremltools）"
pip install "torch>=2.3" "numpy<2" "coremltools>=8.1" "transformers>=4.49" "accelerate" "pillow" >/dev/null

# 採用は SmolVLM-500M（高品質・ADR-34）。SMOLVLM_MODEL で 256M 等へ差し替え可。視覚のみ INT8（既定）。
SMOLVLM_MODEL="${SMOLVLM_MODEL:-HuggingFaceTB/SmolVLM-500M-Instruct}"
echo "==> 3) Core ML へ変換（$SMOLVLM_MODEL・DL 含め 20〜40 分・初回はモデル ~1GB をダウンロード）"
SMOLVLM_MODEL="$SMOLVLM_MODEL" python "$ROOT/scripts/convert_smolvlm.py" "$OUT" --work "$WORK"

echo "==> 完了。生成物:"
ls -la "$OUT"
echo
echo "次: Xcode で MosaicPhotos/VLM/ がターゲットに含まれることを確認してビルド。"
echo "    モデル未同梱でもアプリは動作し、VLM キャプション（AI アルバムの精度向上）だけ無効化される。"
