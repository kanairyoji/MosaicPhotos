#!/usr/bin/env python3
"""検索品質ハーネス（SearchQualityTests）用フィクスチャ生成。手動実行専用・CI とは無関係。

Imagenette（10クラス）から各クラス N 枚を採り、出荷する Core ML CLIP 画像エンコーダで
埋め込みを計算して JSON に書き出す。シミュレータの画像タワーは fp16 NaN のため、
画像埋め込みは Mac（CPU_ONLY・検証済み）で前計算し、テストは検索ロジックだけを回す。

前提: bash scripts/build_mobileclip.sh 済み（venv・モデル）＋ scripts/eval_recognition.sh を
一度実行して Imagenette 取得済み。
使い方: source .mobileclip_build/venv/bin/activate && python scripts/gen_eval_fixture.py
出力: .mobileclip_build/eval/fixture.json
"""
import base64
import json
import os
import random
import struct
import sys

import numpy as np
import coremltools as ct
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "MosaicPhotos/MobileCLIP")
IMAGES_DIR = os.path.join(ROOT, ".mobileclip_build/imagenette/imagenette2-160/val")
OUT_DIR = os.path.join(ROOT, ".mobileclip_build/eval")
PER_CLASS = int(os.environ.get("PER_CLASS", "20"))
SEED = 0

WNIDS = ["n01440764", "n02102040", "n02979186", "n03000684", "n03028079",
         "n03394916", "n03417042", "n03425413", "n03445777", "n03888257"]


def preprocess(path, size):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    s = size / min(w, h)
    im = im.resize((max(size, round(w * s)), max(size, round(h * s))), Image.BICUBIC)
    w, h = im.size
    left, top = (w - size) // 2, (h - size) // 2
    return im.crop((left, top, left + size, top + size))


def main():
    cfg = json.load(open(os.path.join(MODEL_DIR, "mobileclip_config.json")))
    size = int(cfg.get("imageSize", 224))
    img_model = ct.models.MLModel(os.path.join(MODEL_DIR, "MobileCLIPImageS2.mlpackage"),
                                  compute_units=ct.ComputeUnit.CPU_ONLY)
    rng = random.Random(SEED)
    photos = []
    for wnid in WNIDS:
        cdir = os.path.join(IMAGES_DIR, wnid)
        files = sorted(f for f in os.listdir(cdir) if f.lower().endswith((".jpeg", ".jpg")))
        rng.shuffle(files)
        picked = files[:PER_CLASS]
        for i, f in enumerate(picked):
            p = os.path.join(cdir, f)
            vec = np.array(img_model.predict({"image": preprocess(p, size)})["embedding"],
                           dtype=np.float32).reshape(-1)
            if not np.all(np.isfinite(vec)):
                print(f"skip non-finite: {p}", file=sys.stderr)
                continue
            photos.append({
                "refKey": f"L-eval-{wnid}-{i:03d}",
                "wnid": wnid,
                "file": os.path.relpath(p, ROOT),
                # fp32 LE をそのまま base64（Swift 側は ClipMath.encode 済み Data として扱える）
                "vec": base64.b64encode(struct.pack(f"<{len(vec)}f", *vec)).decode(),
            })
        print(f"{wnid}: {len(picked)} photos embedded")
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "fixture.json")
    json.dump({"imageSize": size, "photos": photos}, open(out, "w"))
    print(f"wrote {out} ({len(photos)} photos)")


if __name__ == "__main__":
    main()
