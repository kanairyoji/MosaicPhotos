#!/usr/bin/env python3
"""オンデバイス画像認識（CLIP）の認識率を測るチューニング用プログラム。

⚠️ これはユニットテスト/CI とは完全に独立した「手動実行専用」のツール。
   出荷する Core ML モデル（MosaicPhotos/MobileCLIP/*.mlpackage）を coremltools で
   そのまま実行し、Imagenette（ImageNet 自由配布サブセット・10クラス）に対する
   zero-shot top-1 認識率を「X/100」で表示する。fp16 変換の影響も込みで検証できる。

呼び出しは scripts/eval_recognition.sh 経由（venv・データ取得を面倒見る）。
"""
import argparse
import json
import os
import random
import sys

import numpy as np
import coremltools as ct
from PIL import Image

# Imagenette の WNID → 人間可読ラベル（zero-shot の候補クラス）。
IMAGENETTE = {
    "n01440764": "tench",
    "n02102040": "English springer",
    "n02979186": "cassette player",
    "n03000684": "chain saw",
    "n03028079": "church",
    "n03394916": "French horn",
    "n03417042": "garbage truck",
    "n03425413": "gas pump",
    "n03445777": "golf ball",
    "n03888257": "parachute",
}
PROMPT = "a photo of a {}"


def load_tokenizer():
    import mobileclip
    return mobileclip.get_tokenizer("mobileclip_s2")


def preprocess(path, size):
    """MobileCLIP の前処理（Resize→CenterCrop・[0,1] は Core ML 側 scale で実施）。"""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    s = size / min(w, h)
    im = im.resize((max(size, round(w * s)), max(size, round(h * s))), Image.BICUBIC)
    w, h = im.size
    left, top = (w - size) // 2, (h - size) // 2
    return im.crop((left, top, left + size, top + size))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--images-dir", required=True, help="<dir>/<wnid>/*.JPEG の構造")
    ap.add_argument("--per-class", type=int, default=10)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--compute-units", default="CPU_ONLY",
                    choices=["CPU_ONLY", "ALL", "CPU_AND_NE", "CPU_AND_GPU"])
    args = ap.parse_args()
    random.seed(args.seed)

    cfg = json.load(open(os.path.join(args.model_dir, "mobileclip_config.json")))
    size = int(cfg.get("imageSize", 256))
    ctx = int(cfg.get("contextLength", 77))

    cu = getattr(ct.ComputeUnit, args.compute_units)
    print(f"== loading Core ML models (compute_units={args.compute_units}, imageSize={size}) ==")
    img_model = ct.models.MLModel(os.path.join(args.model_dir, "MobileCLIPImageS2.mlpackage"), compute_units=cu)
    txt_model = ct.models.MLModel(os.path.join(args.model_dir, "MobileCLIPTextS2.mlpackage"), compute_units=cu)
    tokenizer = load_tokenizer()

    # --- クラス（候補ラベル）のテキスト埋め込みを事前計算 ---
    wnids = list(IMAGENETTE.keys())
    class_vecs = []
    for wnid in wnids:
        toks = tokenizer([PROMPT.format(IMAGENETTE[wnid])]).numpy().astype(np.int32).reshape(1, ctx)
        out = txt_model.predict({"text": toks})
        class_vecs.append(np.array(out["embedding"]).reshape(-1))
    class_mat = np.stack(class_vecs)  # [C, D]（モデル出力は正規化済み）

    # --- 画像をサンプリングして評価 ---
    total, correct, nan_count = 0, 0, 0
    per_class = {w: [0, 0] for w in wnids}   # wnid -> [correct, total]
    mistakes = []
    for wnid in wnids:
        cdir = os.path.join(args.images_dir, wnid)
        if not os.path.isdir(cdir):
            continue
        files = [f for f in os.listdir(cdir) if f.lower().endswith((".jpeg", ".jpg", ".png"))]
        random.shuffle(files)
        for fname in files[:args.per_class]:
            try:
                im = preprocess(os.path.join(cdir, fname), size)
                out = img_model.predict({"image": im})
            except Exception as e:
                print(f"  ! predict failed for {fname}: {e}")
                continue
            vec = np.array(out["embedding"]).reshape(-1)
            total += 1
            per_class[wnid][1] += 1
            if not np.all(np.isfinite(vec)):
                nan_count += 1
                continue  # NaN/Inf は不正解扱い
            scores = class_mat @ vec
            pred = int(np.argmax(scores))
            if wnids[pred] == wnid:
                correct += 1
                per_class[wnid][0] += 1
            elif len(mistakes) < 12:
                mistakes.append((IMAGENETTE[wnid], IMAGENETTE[wnids[pred]], fname))

    # --- 結果 ---
    print("\n== per-class (correct/total) ==")
    for wnid in wnids:
        c, t = per_class[wnid]
        if t:
            print(f"  {IMAGENETTE[wnid]:<18} {c}/{t}")
    if mistakes:
        print("\n== sample mistakes (true -> predicted) ==")
        for true_l, pred_l, fn in mistakes:
            print(f"  {true_l} -> {pred_l}   ({fn})")
    if nan_count:
        print(f"\n⚠️ NaN/Inf embeddings: {nan_count}/{total} "
              f"(fp16 が compute_units={args.compute_units} で不安定な可能性)")
    pct = (100.0 * correct / total) if total else 0.0
    print(f"\n=== RECOGNITION: {correct}/{total}  ({pct:.1f}%) ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
