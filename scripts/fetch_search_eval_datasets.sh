#!/usr/bin/env bash
#
# 検索品質（AI アルバム）の評価用データセットを取得する。手動実行専用。
#
# 何のためか:
#   既存の SearchQualityTests（Imagenette）は**肯定側の Recall** を測る。一方で実障害は
#   「『人が写っていない風景』に人が混ざる」＝**除外条件の precision** で、Imagenette には
#   人物の正解ラベルが無く測れなかった。COCO は 80 クラスの物体アノテーションを持ち、
#   person を含むので「〜が写っていない」を正解付きで評価できる。
#
# 何を取るか:
#   COCO 2017 の**ラベルのみ**（画像は取らない・約 46MB）。Ultralytics 配布の YOLO 形式で、
#   1 画像 1 テキスト、各行が「クラス番号 x y w h」。ここから
#   「画像 → 写っているクラスの集合＋個数」が決定的に得られる＝評価の正解になる。
#   ⚠️ 本家 images.cocodataset.org は環境によって TLS 検証に失敗するため GitHub Releases を使う。
#
# 使い方:
#   scripts/fetch_search_eval_datasets.sh
#   → .search_eval/coco/labels/val2017/*.txt を配置し、評価用の要約 JSON を書き出す
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.search_eval"
COCO="$WORK/coco"
URL="https://github.com/ultralytics/yolov5/releases/download/v1.0/coco2017labels.zip"
SUMMARY="$WORK/coco_val2017_labels.json"

mkdir -p "$WORK"

if [ ! -d "$COCO/labels/val2017" ]; then
  echo "▶ COCO 2017 ラベルを取得（約46MB・画像は取らない）…"
  curl -L --fail --max-time 900 -o "$WORK/coco2017labels.zip" "$URL"
  echo "▶ 展開…"
  unzip -q -o "$WORK/coco2017labels.zip" -d "$WORK"
  rm -f "$WORK/coco2017labels.zip"
  # 展開直後は $WORK/coco/labels/... になる（アーカイブの構造に追従）
  [ -d "$COCO/labels/val2017" ] || { echo "❌ 展開後の構造が想定と違う: $COCO"; ls -R "$WORK" | head -20; exit 1; }
fi

echo "▶ 評価用の要約 JSON を作成…"
python3 - "$COCO/labels/val2017" "$SUMMARY" <<'PY'
import json, os, sys, collections

labels_dir, out_path = sys.argv[1], sys.argv[2]

# YOLO 形式の COCO クラス順（80 クラス）。person が 0。
NAMES = [
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light",
    "fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow",
    "elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee",
    "skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard",
    "tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
    "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair","couch",
    "potted plant","bed","dining table","toilet","tv","laptop","mouse","remote","keyboard",
    "cell phone","microwave","oven","toaster","sink","refrigerator","book","clock","vase",
    "scissors","teddy bear","hair drier","toothbrush",
]

images = {}
freq = collections.Counter()
for name in sorted(os.listdir(labels_dir)):
    if not name.endswith(".txt"):
        continue
    stem = name[:-4]
    counts = collections.Counter()
    with open(os.path.join(labels_dir, name)) as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            try:
                cls = int(parts[0])
            except ValueError:
                continue
            if 0 <= cls < len(NAMES):
                counts[NAMES[cls]] += 1
    images[stem] = dict(counts)
    for k in counts:
        freq[k] += 1

# 空ラベル（写っている物体が 1 つも無い画像）も評価対象として残す＝「人がいない」の正例になる。
out = {
    "_readme": "COCO val2017 のラベル要約（画像 → クラス名 → 個数）。検索品質評価の正解。",
    "classes": NAMES,
    "imageFrequency": dict(freq.most_common()),
    "images": images,
}
with open(out_path, "w") as f:
    json.dump(out, f, ensure_ascii=False)

withp = sum(1 for v in images.values() if v.get("person", 0) > 0)
print(f"  画像={len(images)}  person あり={withp}  person なし={len(images)-withp}")
print(f"  出力: {out_path}")
PY

# --- Caltech-101（語彙接地の評価用・約126MB） ---
# 上位概念→下位概念（食べ物→ピザ、楽器→サックス）の階層を正解として書けるデータセット。
# COCO は物体中心で上位語が薄く、この評価には向かない。
if [ ! -d "$WORK/101_ObjectCategories" ]; then
  echo "▶ Caltech-101 を取得（約126MB）…"
  curl -L --fail --max-time 900 -o "$WORK/caltech_101.tgz" \
    "https://s3.amazonaws.com/fast-ai-imageclas/caltech_101.tgz"
  tar xzf "$WORK/caltech_101.tgz" -C "$WORK"
  rm -f "$WORK/caltech_101.tgz"
fi
echo "  Caltech-101: $(ls "$WORK/101_ObjectCategories" | wc -l | tr -d ' ') クラス"

echo "✅ 完了。評価の実行方法は docs/architecture-note/records/search-quality.md を参照。"
