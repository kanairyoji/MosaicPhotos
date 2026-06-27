#!/usr/bin/env python3
"""オンデバイス画像認識（CLIP）の認識率を測るチューニング用プログラム。

⚠️ ユニットテスト/CI とは完全に独立した「手動実行専用」のツール。
   出荷する Core ML モデル（MosaicPhotos/MobileCLIP/*.mlpackage）を coremltools で
   そのまま実行し、認識率を測る。fp16 変換の影響も込みで検証できる。

モード:
  classify : 画像に対し候補クラス名のどれが最も近いか（zero-shot top-1）。
             --classes imagenette（10クラス・やさしい）/ imagenet1k（1000クラス・厳しい）
  query    : 自然文クエリで全画像をランキングし、top-1 画像が意図クラスかを判定
             （オープン語彙の実利用に近い retrieval 評価）
  confusion: 指定クラス（--focus-wnid）の誤判定先の内訳と、正解ラベルの top-5 / 順位を分析

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

# Imagenette の WNID → 人間可読ラベル / ImageNet-1k インデックス。
IMAGENETTE = {
    "n01440764": ("tench", 0),
    "n02102040": ("English springer", 217),
    "n02979186": ("cassette player", 482),
    "n03000684": ("chain saw", 491),
    "n03028079": ("church", 497),
    "n03394916": ("French horn", 566),
    "n03417042": ("garbage truck", 569),
    "n03425413": ("gas pump", 571),
    "n03445777": ("golf ball", 574),
    "n03888257": ("parachute", 701),
}

# 自然文クエリ（クラス名を直接言わない自由表現）→ 正解 WNID。オープン語彙 retrieval の評価用。
QUERIES = [
    ("a small freshwater fish held by a fisherman", "n01440764"),
    ("a brown and white spaniel dog", "n02102040"),
    ("an old portable audio tape player", "n02979186"),
    ("a power tool for cutting wood", "n03000684"),
    ("a building with a steeple where people worship", "n03028079"),
    ("a brass wind instrument", "n03394916"),
    ("a truck that collects household waste", "n03417042"),
    ("a roadside fuel pump at a station", "n03425413"),
    ("a small white ball used in a sport on grass", "n03445777"),
    ("a canopy used to descend safely from the sky", "n03888257"),
]

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


def embed_text(txt_model, tokenizer, ctx, text):
    toks = tokenizer([text]).numpy().astype(np.int32).reshape(1, ctx)
    return np.array(txt_model.predict({"text": toks})["embedding"]).reshape(-1)


def embed_image(img_model, im):
    return np.array(img_model.predict({"image": im})["embedding"]).reshape(-1)


def sanitize(mat):
    """float64 化し、非有限（fp16 由来の NaN/Inf）行をゼロにする（matmul の警告防止）。"""
    mat = np.asarray(mat, dtype=np.float64)
    mat[~np.all(np.isfinite(mat), axis=1)] = 0.0
    return mat


def sample_images(images_dir, per_class, rng):
    """[(path, wnid)] を返す。<images_dir>/<wnid>/*.JPEG 構造。"""
    out = []
    for wnid in IMAGENETTE:
        cdir = os.path.join(images_dir, wnid)
        if not os.path.isdir(cdir):
            continue
        files = [f for f in os.listdir(cdir) if f.lower().endswith((".jpeg", ".jpg", ".png"))]
        rng.shuffle(files)
        out += [(os.path.join(cdir, f), wnid) for f in files[:per_class]]
    return out


def run_classify(img_model, txt_model, tokenizer, ctx, samples, which):
    if which == "imagenet1k":
        import open_clip
        names = list(open_clip.IMAGENET_CLASSNAMES)            # 1000・index 整合
        target_index = {w: IMAGENETTE[w][1] for w in IMAGENETTE}
        print(f"== building {len(names)} class text embeddings (imagenet1k) ==")
    else:
        wnids = list(IMAGENETTE.keys())
        names = [IMAGENETTE[w][0] for w in wnids]              # 10
        target_index = {w: i for i, w in enumerate(wnids)}     # クラス配列内の位置
        print(f"== building {len(names)} class text embeddings (imagenette) ==")

    class_mat = sanitize(np.stack([embed_text(txt_model, tokenizer, ctx, PROMPT.format(n)) for n in names]))

    total, correct, nan = 0, 0, 0
    per = {w: [0, 0] for w in IMAGENETTE}
    mistakes = []
    for path, wnid in samples:
        vec = embed_image(img_model, preprocess(path, IMG_SIZE))
        total += 1
        per[wnid][1] += 1
        if not np.all(np.isfinite(vec)):
            nan += 1
            continue
        pred = int(np.argmax(class_mat @ vec))
        if pred == target_index[wnid]:
            correct += 1
            per[wnid][0] += 1
        elif len(mistakes) < 15:
            mistakes.append((IMAGENETTE[wnid][0], names[pred], os.path.basename(path)))

    print("\n== per-class (correct/total) ==")
    for w in IMAGENETTE:
        c, t = per[w]
        if t:
            print(f"  {IMAGENETTE[w][0]:<18} {c}/{t}")
    _print_mistakes(mistakes)
    return correct, total, nan


def run_query(img_model, txt_model, tokenizer, ctx, samples):
    print(f"== embedding {len(samples)} images for retrieval ==")
    img_mat = np.stack([embed_image(img_model, preprocess(p, IMG_SIZE)) for p, _ in samples]).astype(np.float64)
    wnids = [w for _, w in samples]
    finite = np.all(np.isfinite(img_mat), axis=1)
    nan = int((~finite).sum())
    img_mat[~finite] = 0.0   # 非有限行は計算前にゼロ化（matmul の overflow/invalid 警告を防ぐ）

    print("\n== query → top-1 image class ==")
    correct = 0
    for text, wnid in QUERIES:
        qv = embed_text(txt_model, tokenizer, ctx, text).astype(np.float64)
        scores = img_mat @ qv
        scores[~finite] = -1e9
        top = int(np.argmax(scores))
        ok = wnids[top] == wnid
        correct += int(ok)
        mark = "✓" if ok else "✗"
        print(f"  {mark} \"{text}\"\n      expected={IMAGENETTE[wnid][0]}  got={IMAGENETTE[wnids[top]][0]}")
    return correct, len(QUERIES), nan


def run_confusion(img_model, txt_model, tokenizer, ctx, samples, focus_wnid):
    """指定クラスの誤判定先（混同分布）と正解ラベルの順位を分析する。"""
    import open_clip
    names = list(open_clip.IMAGENET_CLASSNAMES)
    print(f"== building {len(names)} class text embeddings ==")
    class_mat = sanitize(np.stack([embed_text(txt_model, tokenizer, ctx, PROMPT.format(n)) for n in names]))

    focus_idx = IMAGENETTE[focus_wnid][1]
    focus_name = names[focus_idx]
    imgs = [(p, w) for (p, w) in samples if w == focus_wnid]
    print(f"\n== confusion analysis: '{focus_name}' (wnid={focus_wnid}, index={focus_idx}, n={len(imgs)}) ==")

    top1 = top5 = 0
    ranks = []
    hist = {}
    for path, _ in imgs:
        vec = embed_image(img_model, preprocess(path, IMG_SIZE))
        if not np.all(np.isfinite(vec)):
            continue
        order = np.argsort(-(class_mat @ vec))
        rank = int(np.where(order == focus_idx)[0][0])  # 0-based
        ranks.append(rank + 1)
        top1 += int(rank == 0)
        top5 += int(rank < 5)
        pred = names[int(order[0])]
        hist[pred] = hist.get(pred, 0) + 1

    n = len(ranks)
    print(f"\n  top-1 = {top1}/{n} ({100.0*top1/n:.1f}%)   top-5 = {top5}/{n} ({100.0*top5/n:.1f}%)")
    if ranks:
        rs = sorted(ranks)
        print(f"  正解ラベルの順位: 中央値={rs[len(rs)//2]}  平均={sum(rs)/len(rs):.1f}  最悪={rs[-1]}")
    print("\n  == top-1 予測ラベルの内訳（多い順） ==")
    for label, cnt in sorted(hist.items(), key=lambda kv: -kv[1])[:15]:
        star = "  ← 正解" if label == focus_name else ""
        print(f"    {cnt:>4}  {label}{star}")
    return top1, n, 0


def _print_mistakes(mistakes):
    if mistakes:
        print("\n== sample mistakes (true -> predicted) ==")
        for true_l, pred_l, fn in mistakes:
            print(f"  {true_l} -> {pred_l}   ({fn})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--images-dir", required=True, help="<dir>/<wnid>/*.JPEG の構造")
    ap.add_argument("--mode", default="classify", choices=["classify", "query", "confusion"])
    ap.add_argument("--classes", default="imagenette", choices=["imagenette", "imagenet1k"])
    ap.add_argument("--focus-wnid", default="n02979186", help="confusion モードで分析する WNID（既定: cassette player）")
    ap.add_argument("--per-class", type=int, default=10)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--compute-units", default="CPU_ONLY",
                    choices=["CPU_ONLY", "ALL", "CPU_AND_NE", "CPU_AND_GPU"])
    args = ap.parse_args()

    # 非有限行はゼロ化済み。残る fp16 由来の数値警告（表示のみ・結果に影響なし）は抑制する。
    np.seterr(over="ignore", invalid="ignore")

    cfg = json.load(open(os.path.join(args.model_dir, "mobileclip_config.json")))
    global IMG_SIZE
    IMG_SIZE = int(cfg.get("imageSize", 256))
    ctx = int(cfg.get("contextLength", 77))

    cu = getattr(ct.ComputeUnit, args.compute_units)
    print(f"== loading Core ML models (compute_units={args.compute_units}, imageSize={IMG_SIZE}) ==")
    img_model = ct.models.MLModel(os.path.join(args.model_dir, "MobileCLIPImageS2.mlpackage"), compute_units=cu)
    txt_model = ct.models.MLModel(os.path.join(args.model_dir, "MobileCLIPTextS2.mlpackage"), compute_units=cu)
    tokenizer = load_tokenizer()

    rng = random.Random(args.seed)
    samples = sample_images(args.images_dir, args.per_class, rng)

    if args.mode == "query":
        correct, total, nan = run_query(img_model, txt_model, tokenizer, ctx, samples)
        unit = "queries"
    elif args.mode == "confusion":
        correct, total, nan = run_confusion(img_model, txt_model, tokenizer, ctx, samples, args.focus_wnid)
        unit = "images"
    else:
        correct, total, nan = run_classify(img_model, txt_model, tokenizer, ctx, samples, args.classes)
        unit = "images"

    if nan:
        print(f"\n⚠️ NaN/Inf embeddings: {nan} (fp16 が compute_units={args.compute_units} で不安定な可能性)")
    pct = (100.0 * correct / total) if total else 0.0
    label = args.mode if args.mode == "query" else f"classify/{args.classes}"
    print(f"\n=== RECOGNITION [{label}]: {correct}/{total} {unit}  ({pct:.1f}%) ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
