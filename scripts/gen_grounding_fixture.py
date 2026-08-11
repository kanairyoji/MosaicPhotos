#!/usr/bin/env python3
"""語彙接地（ADR-101）の評価フィクスチャ生成。手動実行専用・CI とは無関係。

何をするか:
  検索評価クエリが使う「人間向けの語」（landscape / food / dog …）と、COCO の 80 クラス
  （＝索引に実在する語彙の代役）との**意味的な近さ**を、出荷する Core ML CLIP テキスト塔で
  計算して JSON に書き出す。

なぜ前計算か:
  macOS のテストレーンには CLIP が無く、シミュレータでの実行は遅い。近さの計算は
  クエリ語 × 語彙の静的な表なので、Mac で 1 回作ればハーネスは純ロジックのまま回せる
  （画像埋め込みを前計算する gen_eval_fixture.py と同じ方針）。

前提: bash scripts/build_mobileclip.sh 済み（venv・モデル）
使い方: source .mobileclip_build/venv/bin/activate && python scripts/gen_grounding_fixture.py
出力: .search_eval/grounding.json
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "MosaicPhotos", "MobileCLIP")
OUT = os.path.join(ROOT, ".search_eval", "grounding.json")
LABELS = os.path.join(ROOT, ".search_eval", "coco_val2017_labels.json")

# 評価クエリ側が使う語（レキシコン/LLM が出す「人間向けの語」）。
TERMS = [
    "landscape", "scenery", "outdoor",
    "food", "meal",
    "dog", "cat", "car", "train", "pizza",
    "people",
]


def main():
    try:
        import coremltools as ct
        import numpy as np
    except ImportError:
        sys.exit("❌ venv が有効でない。source .mobileclip_build/venv/bin/activate してから実行。")

    if not os.path.exists(LABELS):
        sys.exit(f"❌ COCO ラベルが無い: {LABELS}\n   先に scripts/fetch_search_eval_datasets.sh を実行。")
    vocabulary = json.load(open(LABELS))["classes"]

    text_model = os.path.join(MODEL_DIR, "MobileCLIPTextS2.mlpackage")
    if not os.path.exists(text_model):
        sys.exit(f"❌ CLIP テキスト塔が無い: {text_model}\n   先に bash scripts/build_mobileclip.sh を実行。")

    # 出荷モデルは open_clip 由来（scripts/convert_clip.py）なので同じトークナイザを使う。
    try:
        import open_clip
    except ImportError:
        sys.exit("❌ open_clip が無い。source .mobileclip_build/venv/bin/activate してから実行。")
    tokenizer = open_clip.get_tokenizer(os.environ.get("OC_MODEL", "ViT-B-32"))
    model = ct.models.MLModel(text_model, compute_units=ct.ComputeUnit.CPU_ONLY)

    def embed(text):
        # ⚠️ アプリ側（CLIPConceptExpander / CLIPDisplayLabeler）と**同じ定型文**にする。
        tokens = tokenizer([f"a photo of {text}"]).numpy().astype(np.int32)
        out = model.predict({"text": tokens})
        vec = np.array(list(out.values())[0]).reshape(-1).astype(np.float64)
        norm = np.linalg.norm(vec)
        return vec / norm if norm > 0 else vec

    vocab_vectors = np.stack([embed(w) for w in vocabulary])
    table = {}
    for term in TERMS:
        sims = vocab_vectors @ embed(term)
        table[term] = [max(0.0, float(s)) for s in sims]
        top = sorted(zip(vocabulary, table[term]), key=lambda kv: -kv[1])[:6]
        print(f"  {term:12s} → " + ", ".join(f"{w}={s:.3f}" for w, s in top))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump({"_readme": "語 × COCO クラス の CLIP 類似度（ADR-101 の接地評価用）",
               "vocabulary": vocabulary, "similarities": table},
              open(OUT, "w"), ensure_ascii=False)
    print(f"✅ 出力: {OUT}")


if __name__ == "__main__":
    main()
