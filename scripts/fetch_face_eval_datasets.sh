#!/bin/bash
# 顔認識の精度計測用データセットを ~/DEV/tmp/face-eval/ に収集する。
#
# 収集するもの:
#   fgnet/ — FG-NET Aging Database（82 人・約1,000 枚・0〜69 歳の同一人物の成長写真）。
#            ファイル名（例 001A02.JPG = 人物001・2歳）から labels.csv を自動生成する。
#            ⚠️ 学術研究用途で公開されているデータセット。精度計測（内部評価）にのみ使い、
#            アプリへの同梱・再配布はしないこと。
#   own/   — 自前写真用のテンプレート（images/ に写真を置き labels.csv に正解を書く）。
#            実ライブラリの難所（兄弟・成長期）はここに置くのが最も実態に合う。
#
# 実行後の計測:
#   xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
#     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
#     -only-testing:MosaicPhotosTests/FaceAccuracyEvalTests
set -euo pipefail

ROOT="${FACE_EVAL_DIR:-$HOME/DEV/tmp/face-eval}"
mkdir -p "$ROOT"

# --- FG-NET ---
if [ ! -d "$ROOT/fgnet/images" ]; then
  echo "FG-NET をダウンロード中（約 46MB）..."
  TMP_ZIP="$ROOT/fgnet.zip"
  curl -fL --retry 3 -o "$TMP_ZIP" "http://yanweifu.github.io/FG_NET_data/FGNET.zip"
  UNZIP_DIR="$ROOT/fgnet-unzip"
  rm -rf "$UNZIP_DIR"; mkdir -p "$UNZIP_DIR"
  unzip -q "$TMP_ZIP" -d "$UNZIP_DIR"
  mkdir -p "$ROOT/fgnet/images"
  # zip 内の画像ディレクトリ（FGNET/images）を探して平置きにする。
  find "$UNZIP_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) \
    -exec mv {} "$ROOT/fgnet/images/" \;
  rm -rf "$UNZIP_DIR" "$TMP_ZIP"
  echo "FG-NET: $(ls "$ROOT/fgnet/images" | wc -l | tr -d ' ') 枚"
else
  echo "FG-NET: 取得済み（$(ls "$ROOT/fgnet/images" | wc -l | tr -d ' ') 枚）"
fi

# labels.csv 生成（ファイル名 001A02.JPG → person=001, age=02。末尾の a/b は同年齢の別カット）
python3 - "$ROOT/fgnet" <<'PY'
import csv, os, re, sys
root = sys.argv[1]
rows = []
for name in sorted(os.listdir(os.path.join(root, "images"))):
    m = re.match(r"^(\d{3})[Aa](\d{1,2})[a-z]?\.(jpe?g|png)$", name, re.IGNORECASE)
    if m:
        rows.append((name, m.group(1), int(m.group(2))))
with open(os.path.join(root, "labels.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["file", "person", "age"])
    w.writerows(rows)
print(f"fgnet/labels.csv: {len(rows)} 行")
PY

# --- negatives（顔のない画像＝偽陽性計測用。風景・物・猫犬＝顔検出の典型的誤検出源） ---
mkdir -p "$ROOT/negatives/images"
NEG_COUNT=$(ls "$ROOT/negatives/images" 2>/dev/null | wc -l | tr -d ' ')
if [ "$NEG_COUNT" -lt 18 ]; then
  echo "negatives をダウンロード中（Wikimedia Commons・パブリックドメイン/CC0）..."
  i=0
  while IFS= read -r url; do
    i=$((i+1))
    out="$ROOT/negatives/images/neg$(printf %02d $i).jpg"
    # Wikimedia は UA 無しのリクエストを拒否するため UA を明示する。
    [ -f "$out" ] || curl -fsL --retry 2 -A "MosaicPhotosFaceEval/1.0 (internal accuracy testing)" \
      -o "$out" "$url" || echo "  取得失敗（スキップ）: $url"
  done <<'URLS'
https://commons.wikimedia.org/wiki/Special:FilePath/Hopetoun_falls.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Half_Dome_with_Eastern_Yosemite_Valley_%2850MP%29.jpg?width=1024
https://upload.wikimedia.org/wikipedia/commons/a/a5/Tsunami_by_hokusai_19th_century.jpg
https://upload.wikimedia.org/wikipedia/commons/4/45/A_small_cup_of_coffee.JPG
https://upload.wikimedia.org/wikipedia/commons/6/68/Orange_tabby_cat_sitting_on_fallen_leaves-Hisashi-01A.jpg
https://upload.wikimedia.org/wikipedia/commons/2/25/Siam_lilacpoint.jpg
https://upload.wikimedia.org/wikipedia/commons/2/26/YellowLabradorLooking_new.jpg
https://upload.wikimedia.org/wikipedia/commons/1/18/TrailKitty.jpg
https://upload.wikimedia.org/wikipedia/commons/3/3a/Cat03.jpg
https://upload.wikimedia.org/wikipedia/commons/b/b6/Felis_catus-cat_on_snow.jpg
https://commons.wikimedia.org/wiki/Special:FilePath/Poecile_atricapillus_CT3.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Fesa_de_Vella_o_la_Vall_de_Gallinera.JPG?width=1024
https://upload.wikimedia.org/wikipedia/commons/e/e1/FullMoon2010.jpg
https://commons.wikimedia.org/wiki/Special:FilePath/Fronalpstock_big.jpg?width=1024
https://upload.wikimedia.org/wikipedia/commons/1/1a/Bachalpseeflowers.jpg
https://commons.wikimedia.org/wiki/Special:FilePath/Pahoeoe_fountain_original.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Chocolate_Cupcakes_with_Raspberry_Buttercream.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Emperor_Penguin_Manchot_empereur.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Calliphora_sp_Portrait.jpg?width=1024
https://commons.wikimedia.org/wiki/Special:FilePath/Sadovyi_%22Round%22_lake.jpg?width=1024
URLS
fi
echo "negatives: $(ls "$ROOT/negatives/images" | wc -l | tr -d ' ') 枚"

# --- own（自前写真テンプレート） ---
mkdir -p "$ROOT/own/images"
if [ ! -f "$ROOT/own/labels.csv" ]; then
  printf 'file,person,age\n# example.jpg,長男,5\n' > "$ROOT/own/labels.csv"
  echo "own/: 自前写真を own/images/ に置き own/labels.csv に正解を記入してください（age は空欄可）"
fi

echo "完了: $ROOT"
