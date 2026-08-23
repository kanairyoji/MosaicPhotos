#!/bin/bash
# ドキュメント用スクリーンショットの素材写真を取得する。
#
# 素材源: Lorem Picsum (https://picsum.photos) — Unsplash ライセンスの写真を
# シード指定で決定的に配信する（同じシード→同じ写真）。Unsplash License は
# 商用・非商用とも無償・出典表記不要なので、公開ドキュメント・App Store 素材に使える。
#
# 出力: .screenshot_assets/raw/ に JPEG を保存（.gitignore 対象）。
# 次段: scripts/inject_screenshot_exif.swift が撮影日・GPS を書き込む。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=.screenshot_assets/raw
mkdir -p "$OUT"

# シードは「都市名-連番」。inject_screenshot_exif.swift がファイル名から都市を割り当てる。
SEEDS=()
for i in $(seq 1 16); do SEEDS+=("okinawa-$i"); done
for i in $(seq 1 12); do SEEDS+=("kyoto-$i"); done
for i in $(seq 1 8);  do SEEDS+=("hakone-$i"); done
for i in $(seq 1 20); do SEEDS+=("tokyo-$i"); done
for i in $(seq 1 8);  do SEEDS+=("misc-$i"); done

echo "Fetching ${#SEEDS[@]} photos from picsum.photos…"
for seed in "${SEEDS[@]}"; do
  f="$OUT/$seed.jpg"
  if [[ -s "$f" ]]; then continue; fi
  curl -fsSL --retry 3 "https://picsum.photos/seed/$seed/1600/1200.jpg" -o "$f" || {
    echo "  skip $seed (fetch failed)"; rm -f "$f"; continue; }
  printf "."
done
echo
echo "Done: $(ls "$OUT" | wc -l | tr -d ' ') photos in $OUT"
