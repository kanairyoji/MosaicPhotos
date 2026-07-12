#!/usr/bin/env python3
"""CLIP の Core ML 3構成(現行fp16 / INT8 / TinyCLIP)を同一条件で比較する手動ツール。

⚠️ CI とは無関係。Mac + coremltools 実測(相対比較)。iPhone ANE 値ではない。
測るもの: (1)精度=zero-shot top-1(1000クラス識別・判別力高) (2)速度=画像/テキスト1回の推論ms
          (3)メモリ=モデル実体サイズ + プロセスpeak RSS。

使い方(model-dir に mlpackage×2 + mobileclip_config.json がある前提):
  python scripts/bench_clip.py --model-dir MosaicPhotos/MobileCLIP --images-dir <val> \
      --per-class 20 --compute-units CPU_ONLY
"""
import argparse, json, os, random, resource, time, sys
import numpy as np, coremltools as ct
from PIL import Image

IMAGENETTE = {
    "n01440764": ("tench", 0), "n02102040": ("English springer", 217),
    "n02979186": ("cassette player", 482), "n03000684": ("chain saw", 491),
    "n03028079": ("church", 497), "n03394916": ("French horn", 566),
    "n03417042": ("garbage truck", 569), "n03425413": ("gas pump", 571),
    "n03445777": ("golf ball", 574), "n03888257": ("parachute", 701),
}
PROMPT = "a photo of a {}"

def dir_size_mb(path):
    return sum(f.stat().st_size for f in os.scandir(path) for f in [f] if True) if False else \
        sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(path) for f in fs) / (1024*1024)

def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024*1024)

def preprocess(path, size):
    im = Image.open(path).convert("RGB")
    w, h = im.size; s = size / min(w, h)
    im = im.resize((max(size, round(w*s)), max(size, round(h*s))), Image.BICUBIC)
    w, h = im.size; left, top = (w-size)//2, (h-size)//2
    return im.crop((left, top, left+size, top+size))

def embed_text(txt, tok, ctx, text):
    toks = tok([text]).numpy().astype(np.int32).reshape(1, ctx)
    return np.array(txt.predict({"text": toks})["embedding"]).reshape(-1)

def embed_image(img, im):
    return np.array(img.predict({"image": im})["embedding"]).reshape(-1)

def sanitize(mat):
    mat = np.asarray(mat, dtype=np.float64)
    mat[~np.all(np.isfinite(mat), axis=1)] = 0.0
    return mat

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--images-dir", required=True)
    ap.add_argument("--per-class", type=int, default=20)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--latency-runs", type=int, default=30)
    ap.add_argument("--compute-units", default="CPU_ONLY",
                    choices=["CPU_ONLY", "ALL", "CPU_AND_NE", "CPU_AND_GPU"])
    a = ap.parse_args()
    np.seterr(over="ignore", invalid="ignore")

    import mobileclip
    tok = mobileclip.get_tokenizer("mobileclip_s2")
    cfg = json.load(open(os.path.join(a.model_dir, "mobileclip_config.json")))
    size = int(cfg.get("imageSize", 224)); ctx = int(cfg.get("contextLength", 77))
    cu = getattr(ct.ComputeUnit, a.compute_units)
    img = ct.models.MLModel(os.path.join(a.model_dir, "MobileCLIPImageS2.mlpackage"), compute_units=cu)
    txt = ct.models.MLModel(os.path.join(a.model_dir, "MobileCLIPTextS2.mlpackage"), compute_units=cu)

    # ---- accuracy: 1000クラス zero-shot top-1 (Imagenette 画像を 1000 ラベルで識別) ----
    import open_clip
    names = list(open_clip.IMAGENET_CLASSNAMES)
    class_mat = sanitize(np.stack([embed_text(txt, tok, ctx, PROMPT.format(n)) for n in names]))
    rng = random.Random(a.seed)
    samples = []
    for wnid in IMAGENETTE:
        cdir = os.path.join(a.images_dir, wnid)
        if not os.path.isdir(cdir): continue
        fs = [f for f in os.listdir(cdir) if f.lower().endswith((".jpeg", ".jpg", ".png"))]
        rng.shuffle(fs); samples += [(os.path.join(cdir, f), wnid) for f in fs[:a.per_class]]
    correct = total = nan = 0
    for path, wnid in samples:
        vec = embed_image(img, preprocess(path, size)); total += 1
        if not np.all(np.isfinite(vec)): nan += 1; continue
        if int(np.argmax(class_mat @ vec)) == IMAGENETTE[wnid][1]: correct += 1
    acc = 100.0 * correct / total if total else 0.0

    # ---- latency: 画像/テキスト 1回の推論(ウォームアップ後の中央値) ----
    one_img = preprocess(samples[0][0], size)
    for _ in range(3): embed_image(img, one_img)
    ti = []
    for _ in range(a.latency_runs):
        t = time.time(); embed_image(img, one_img); ti.append((time.time()-t)*1000)
    for _ in range(3): embed_text(txt, tok, ctx, "a photo of a dog")
    tt = []
    for _ in range(a.latency_runs):
        t = time.time(); embed_text(txt, tok, ctx, "a photo of a dog"); tt.append((time.time()-t)*1000)
    ti.sort(); tt.sort()

    img_mb = dir_size_mb(os.path.join(a.model_dir, "MobileCLIPImageS2.mlpackage"))
    txt_mb = dir_size_mb(os.path.join(a.model_dir, "MobileCLIPTextS2.mlpackage"))
    res = {
        "model": cfg.get("model"), "compute_units": a.compute_units,
        "size_MB": {"image": round(img_mb), "text": round(txt_mb), "total": round(img_mb+txt_mb)},
        "accuracy_top1_pct": round(acc, 1), "n_images": total, "nan": nan,
        "img_latency_ms": {"median": round(ti[len(ti)//2], 1), "min": round(ti[0], 1)},
        "txt_latency_ms": {"median": round(tt[len(tt)//2], 1), "min": round(tt[0], 1)},
        "rss_peak_MB": round(rss_mb()),
    }
    print("RESULT " + json.dumps(res, ensure_ascii=False))
    return 0

if __name__ == "__main__":
    sys.exit(main())
