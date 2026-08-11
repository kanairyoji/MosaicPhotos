#!/usr/bin/env python3
"""S8（ADR-102）: 多言語テキスト塔の採否を**数字で**決めるベンチ。手動実行専用。

問い: 日本語クエリを翻訳なしで CLIP 画像空間と比較できるか（FM 翻訳依存とレキシコンを
原理的に不要にできるか）。

条件（Imagenette 10 クラスのゼロショット top-1）:
  A) 出荷 CLIP（datacomp）＋英語クエリ           … 現行の上限（翻訳が完璧な場合）
  B) 多言語テキスト塔＋**出荷の** datacomp 画像塔  … 空間不一致の検証（蒸留先は OpenAI 空間）
  C) 多言語テキスト塔＋OpenAI ViT-B/32 画像塔     … 両塔を載せ替えた場合に得られる性能
  D) OpenAI ViT-B/32 の自前テキスト塔＋英語クエリ  … C の上限（載せ替え後の英語性能）

⚠️ B が低く C が高ければ「載せ替えれば成立するが、全写真の再埋め込み
（perceptionVersion 採番）が必要」という判断材料になる。
前提: build_mobileclip.sh 済み・eval_recognition.sh 済み（Imagenette 取得済み）。
使い方: source .mobileclip_build/venv/bin/activate && python scripts/bench_multilingual_query.py
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, ".mobileclip_build", "imagenette", "imagenette2-160", "val")
MODEL_DIR = os.path.join(ROOT, "MosaicPhotos", "MobileCLIP")
PER_CLASS = int(os.environ.get("PER_CLASS", "20"))

# Imagenette の 10 クラス（wnid → 英語 / 日本語クエリ）。
CLASSES = {
    "n01440764": ("tench fish", "テンチという魚"),
    "n02102040": ("english springer spaniel dog", "スパニエル犬"),
    "n02979186": ("cassette player", "カセットプレーヤー"),
    "n03000684": ("chain saw", "チェーンソー"),
    "n03028079": ("church", "教会"),
    "n03394916": ("french horn", "ホルン"),
    "n03417042": ("garbage truck", "ゴミ収集車"),
    "n03425413": ("gas station", "ガソリンスタンド"),
    "n03445777": ("golf ball", "ゴルフボール"),
    "n03888257": ("parachute", "パラシュート"),
}


def main():
    import numpy as np
    import coremltools as ct
    from PIL import Image
    import open_clip
    import torch
    from sentence_transformers import SentenceTransformer

    if not os.path.isdir(DATA):
        sys.exit(f"❌ Imagenette が無い: {DATA}\n   先に scripts/eval_recognition.sh を実行。")

    wnids = list(CLASSES.keys())

    # --- 画像を集める（各クラス PER_CLASS 枚・決定的） ---
    images = {}
    for wnid in wnids:
        folder = os.path.join(DATA, wnid)
        files = sorted(os.listdir(folder))[:PER_CLASS]
        images[wnid] = [os.path.join(folder, f) for f in files]

    def normalize(m):
        n = np.linalg.norm(m, axis=-1, keepdims=True)
        n[n == 0] = 1
        return m / n

    def top1(image_matrix, labels, query_matrix):
        # image_matrix: (N,D) 正規化済み / labels: N のクラス index / query_matrix: (10,D)
        sims = image_matrix @ query_matrix.T
        pred = sims.argmax(axis=1)
        return float((pred == labels).mean())

    labels = np.concatenate([[i] * len(images[w]) for i, w in enumerate(wnids)])

    # --- 出荷 CLIP（datacomp・Core ML） ---
    ship_img = ct.models.MLModel(os.path.join(MODEL_DIR, "MobileCLIPImageS2.mlpackage"),
                                 compute_units=ct.ComputeUnit.CPU_ONLY)
    ship_txt = ct.models.MLModel(os.path.join(MODEL_DIR, "MobileCLIPTextS2.mlpackage"),
                                 compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = ship_img.get_spec()
    inp = spec.description.input[0]
    side = inp.type.imageType.width or 224
    tokenizer = open_clip.get_tokenizer("ViT-B-32")

    def ship_embed_image(path):
        img = Image.open(path).convert("RGB").resize((side, side), Image.BICUBIC)
        out = ship_img.predict({inp.name: img})
        return np.array(list(out.values())[0]).reshape(-1)

    def ship_embed_text(text):
        tokens = tokenizer([f"a photo of {text}"]).numpy().astype(np.int32)
        out = ship_txt.predict({"text": tokens})
        return np.array(list(out.values())[0]).reshape(-1)

    print("▶ 出荷 CLIP で画像埋め込み…", flush=True)
    ship_imgs = normalize(np.stack([ship_embed_image(p) for w in wnids for p in images[w]]))
    ship_en = normalize(np.stack([ship_embed_text(CLASSES[w][0]) for w in wnids]))
    acc_a = top1(ship_imgs, labels, ship_en)
    print(f"A) 出荷CLIP + 英語        top-1 = {acc_a:.2f}")

    # --- 多言語テキスト塔（OpenAI CLIP 空間へ蒸留） ---
    print("▶ 多言語テキスト塔をロード…", flush=True)
    multi = SentenceTransformer("sentence-transformers/clip-ViT-B-32-multilingual-v1")
    multi_ja = normalize(np.stack([multi.encode(f"{CLASSES[w][1]}の写真") for w in wnids]))
    acc_b = top1(ship_imgs, labels, multi_ja)
    print(f"B) 多言語(ja) + 出荷画像塔 top-1 = {acc_b:.2f}   ← 空間不一致の検証")

    # --- OpenAI ViT-B/32（載せ替え後の姿） ---
    print("▶ OpenAI ViT-B/32 をロード…", flush=True)
    oai_model, _, oai_pre = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
    oai_model.eval()

    def oai_embed_image(path):
        img = oai_pre(Image.open(path).convert("RGB")).unsqueeze(0)
        with torch.no_grad():
            return oai_model.encode_image(img).numpy().reshape(-1)

    def oai_embed_text(text):
        tokens = tokenizer([f"a photo of {text}"])
        with torch.no_grad():
            return oai_model.encode_text(tokens).numpy().reshape(-1)

    print("▶ OpenAI 画像埋め込み…", flush=True)
    oai_imgs = normalize(np.stack([oai_embed_image(p) for w in wnids for p in images[w]]))
    acc_c = top1(oai_imgs, labels, multi_ja)
    acc_d = top1(oai_imgs, labels,
                 normalize(np.stack([oai_embed_text(CLASSES[w][0]) for w in wnids])))
    print(f"C) 多言語(ja) + OpenAI画像塔 top-1 = {acc_c:.2f}   ← 載せ替え後の日本語性能")
    print(f"D) OpenAI英語 + OpenAI画像塔 top-1 = {acc_d:.2f}   ← 載せ替え後の英語上限")

    out = {"A_ship_en": acc_a, "B_multi_ja_ship_img": acc_b,
           "C_multi_ja_openai_img": acc_c, "D_openai_en": acc_d,
           "perClass": PER_CLASS}
    path = os.path.join(ROOT, ".search_eval", "multilingual_bench.json")
    json.dump(out, open(path, "w"))
    print(f"✅ 出力: {path}")


if __name__ == "__main__":
    main()
