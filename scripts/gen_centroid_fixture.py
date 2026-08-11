#!/usr/bin/env python3
"""語彙接地（ADR-101）の**重心版**評価フィクスチャ生成。手動実行専用・CI とは無関係。

何を作るか:
  Caltech-101（101 クラス・約126MB）の各クラスについて、出荷する Core ML CLIP **画像**塔で
  埋め込みを計算し、クラスごとの**重心**（平均ベクトル・L2 正規化）を作る。
  併せて評価クエリ語の**テキスト**埋め込みも計算し、
    - text↔text 類似度（クラス名との比較。ADR-101 で不十分と判明した方式）
    - text↔image 類似度（重心との比較。重心版）
  の両方を書き出す。**同じ正解に対して両方式を比べられる**ようにするのが目的。

なぜ Caltech-101 か:
  上位概念→下位概念の展開（「食べ物→ピザ」「楽器→サックス」）を正解付きで測りたい。
  COCO の 80 クラスは物体中心で上位語が薄く、風景・楽器・花などの階層が作れない。
  Caltech-101 は pizza / 各種楽器 / 花 / 乗り物 / 動物が揃い、階層を書ける。

前提: bash scripts/build_mobileclip.sh 済み＋ scripts/fetch_search_eval_datasets.sh 済み
使い方: source .mobileclip_build/venv/bin/activate && python scripts/gen_centroid_fixture.py
出力: .search_eval/centroids.json
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "MosaicPhotos", "MobileCLIP")
CATEGORIES = os.path.join(ROOT, ".search_eval", "101_ObjectCategories")
OUT = os.path.join(ROOT, ".search_eval", "centroids.json")

# 1 クラスあたりの枚数上限。重心は平均なので数十枚あれば安定する（全部使うと遅いだけ）。
PER_CLASS = int(os.environ.get("PER_CLASS", "40"))

# 評価する「人間向けの語」。索引語彙（クラス名）にそのまま無い上位概念を中心に選ぶ。
TERMS = [
    "food", "musical instrument", "vehicle", "animal", "flower",
    "insect", "bird", "furniture", "landscape", "face",
    # 語彙にそのまま在る語（完全一致が効くかの対照）
    "pizza", "laptop", "umbrella",
    # 雑音語（S6・ADR-102）: 視覚概念として語彙に相当物が無い語。凝集度規則が
    # これらを**接地しない**ことを確認するための負例。
    "nostalgia", "happiness", "software", "freedom", "delicious",
]


def main():
    try:
        import coremltools as ct
        import numpy as np
        from PIL import Image
    except ImportError:
        sys.exit("❌ venv が有効でない。source .mobileclip_build/venv/bin/activate してから実行。")

    if not os.path.isdir(CATEGORIES):
        sys.exit(f"❌ Caltech-101 が無い: {CATEGORIES}\n   先に scripts/fetch_search_eval_datasets.sh を実行。")

    image_model_path = os.path.join(MODEL_DIR, "MobileCLIPImageS2.mlpackage")
    text_model_path = os.path.join(MODEL_DIR, "MobileCLIPTextS2.mlpackage")
    for p in (image_model_path, text_model_path):
        if not os.path.exists(p):
            sys.exit(f"❌ CLIP モデルが無い: {p}\n   先に bash scripts/build_mobileclip.sh を実行。")

    import open_clip
    tokenizer = open_clip.get_tokenizer(os.environ.get("OC_MODEL", "ViT-B-32"))
    image_model = ct.models.MLModel(image_model_path, compute_units=ct.ComputeUnit.CPU_ONLY)
    text_model = ct.models.MLModel(text_model_path, compute_units=ct.ComputeUnit.CPU_ONLY)

    # 画像塔の入力仕様（サイズ）をモデルから読む＝変換時の設定に追従する。
    spec = image_model.get_spec()
    image_input = spec.description.input[0]
    side = image_input.type.imageType.width or 224

    def embed_text(text):
        tokens = tokenizer([f"a photo of {text}"]).numpy().astype(np.int32)
        out = text_model.predict({"text": tokens})
        vec = np.array(list(out.values())[0]).reshape(-1).astype(np.float64)
        n = np.linalg.norm(vec)
        return vec / n if n > 0 else vec

    def embed_image(path):
        img = Image.open(path).convert("RGB").resize((side, side), Image.BICUBIC)
        out = image_model.predict({image_input.name: img})
        vec = np.array(list(out.values())[0]).reshape(-1).astype(np.float64)
        n = np.linalg.norm(vec)
        return vec / n if n > 0 else None

    classes = sorted(d for d in os.listdir(CATEGORIES)
                     if os.path.isdir(os.path.join(CATEGORIES, d)) and d != "BACKGROUND_Google")
    centroids, kept_classes, counts = [], [], {}
    for i, cls in enumerate(classes):
        folder = os.path.join(CATEGORIES, cls)
        files = sorted(f for f in os.listdir(folder) if f.lower().endswith((".jpg", ".jpeg", ".png")))[:PER_CLASS]
        vecs = []
        for f in files:
            v = embed_image(os.path.join(folder, f))
            if v is not None:
                vecs.append(v)
        if len(vecs) < 5:      # 枚数が少なすぎる重心は不安定なので語彙から外す
            continue
        c = np.mean(np.stack(vecs), axis=0)
        n = np.linalg.norm(c)
        centroids.append(c / n if n > 0 else c)
        kept_classes.append(cls)
        counts[cls] = len(vecs)
        print(f"  [{i+1}/{len(classes)}] {cls:22s} {len(vecs):3d} 枚", flush=True)

    centroid_matrix = np.stack(centroids)
    # クラス名は語彙語として扱えるよう正規化（`car_side` → `car side`）。
    vocabulary = [c.replace("_", " ").lower() for c in kept_classes]
    name_vectors = np.stack([embed_text(v) for v in vocabulary])

    text_text, text_image = {}, {}
    for term in TERMS:
        q = embed_text(term)
        text_text[term] = [max(0.0, float(s)) for s in (name_vectors @ q)]
        text_image[term] = [max(0.0, float(s)) for s in (centroid_matrix @ q)]

    json.dump({
        "_readme": "Caltech-101 の語彙。textText=クラス名との類似度 / textImage=クラス重心との類似度（ADR-101）",
        "vocabulary": vocabulary,
        # 重心どうしの相互類似（S6 の凝集度規則用・小数4桁に丸め）。
        "centroidMutual": [[round(float(x), 4) for x in (centroid_matrix @ c)] for c in centroid_matrix],
        "imagesPerClass": counts,
        "textText": text_text,
        "textImage": text_image,
    }, open(OUT, "w"), ensure_ascii=False)
    print(f"✅ 出力: {OUT}（語彙 {len(vocabulary)} クラス）")


if __name__ == "__main__":
    main()
