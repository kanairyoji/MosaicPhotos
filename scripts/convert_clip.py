#!/usr/bin/env python3
"""open_clip の任意モデルを Core ML(.mlpackage) へ変換する（権利フリーモデル比較用）。

環境変数:
  OC_MODEL       open_clip モデル名（例: ViT-B-32）または hf-hub:repo
  OC_PRETRAINED  pretrained タグ（例: openai）。hf-hub: 指定時は空でよい
  OUT            出力ディレクトリ
  CONTEXT        テキスト文脈長（既定 77）

出力（eval/アプリと同じ規約）:
  OUT/MobileCLIPImageS2.mlpackage / MobileCLIPTextS2.mlpackage / mobileclip_config.json

注: OpenAI/OpenCLIP/TinyCLIP は CLIP の mean/std 正規化を行うため、その正規化を
    画像エンコーダ内に内包する（ImageType は scale=1/255 で [0,1] にするだけ）。
    こうするとアプリ側の入力経路は MobileCLIP と同じまま使える。
"""
import json
import os

import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
import open_clip

OC_MODEL = os.environ["OC_MODEL"]
OC_PRETRAINED = os.environ.get("OC_PRETRAINED", "") or None
OUT = os.environ["OUT"]
CONTEXT = int(os.environ.get("CONTEXT", "77"))

os.makedirs(OUT, exist_ok=True)
print("loading:", OC_MODEL, OC_PRETRAINED)
model, _, preprocess = open_clip.create_model_and_transforms(OC_MODEL, pretrained=OC_PRETRAINED)
model.eval()

# preprocess から image_size と Normalize(mean,std) を取得
img_size = 224
mean = [0.48145466, 0.4578275, 0.40821073]
std = [0.26862954, 0.26130258, 0.27577711]
for t in getattr(preprocess, "transforms", []):
    size = getattr(t, "size", None)
    if isinstance(size, int):
        img_size = size
    elif isinstance(size, (tuple, list)) and size:
        img_size = size[0]
    if t.__class__.__name__ == "Normalize":
        mean = list(t.mean); std = list(t.std)
print("image size:", img_size, "mean:", mean, "std:", std)


class ImageEncoder(nn.Module):
    def __init__(self, m, mean, std):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))

    def forward(self, x):  # x: [0,1] RGB（ImageType scale=1/255）。ここで CLIP 正規化を内包。
        x = (x - self.mean) / self.std
        f = self.m.encode_image(x)
        return f / f.norm(dim=-1, keepdim=True)


class TextEncoder(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, tokens):  # int32 [1, CONTEXT]
        f = self.m.encode_text(tokens)
        return f / f.norm(dim=-1, keepdim=True)


img_example = torch.rand(1, 3, img_size, img_size)
img_traced = torch.jit.trace(ImageEncoder(model, mean, std), img_example, check_trace=False)
embed_dim = int(img_traced(img_example).shape[-1])
print("embedding dim:", embed_dim)

# INT8 重み量子化（QUANTIZE=int8 のとき）。重みのみ int8・線形対称で fp16 の約半分に。
# 精度はほぼ不変（ViT-B-32 で zero-shot 75→76%＝誤差）。ADR-31 / case-studies 参照。
QUANTIZE = os.environ.get("QUANTIZE", "").lower()
def maybe_quantize(mlmodel):
    if QUANTIZE != "int8":
        return mlmodel
    import coremltools.optimize.coreml as cto
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", weight_threshold=512))
    return cto.linear_quantize_weights(mlmodel, cfg)

img_ml = ct.convert(
    img_traced,
    inputs=[ct.ImageType(name="image", shape=img_example.shape, scale=1 / 255.0, bias=[0, 0, 0])],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,   # 実機 ANE 前提
)
maybe_quantize(img_ml).save(os.path.join(OUT, "MobileCLIPImageS2.mlpackage"))
print("saved image encoder" + (" (int8)" if QUANTIZE == "int8" else ""))

txt_example = torch.zeros(1, CONTEXT, dtype=torch.int32)
txt_traced = torch.jit.trace(TextEncoder(model), txt_example, check_trace=False)
txt_ml = ct.convert(
    txt_traced,
    inputs=[ct.TensorType(name="text", shape=(1, CONTEXT), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
maybe_quantize(txt_ml).save(os.path.join(OUT, "MobileCLIPTextS2.mlpackage"))
print("saved text encoder" + (" (int8)" if QUANTIZE == "int8" else ""))

with open(os.path.join(OUT, "mobileclip_config.json"), "w") as f:
    json.dump({"imageSize": img_size, "contextLength": CONTEXT, "embedDim": embed_dim,
               "model": OC_MODEL, "pretrained": OC_PRETRAINED or ""}, f, indent=2)
print("wrote mobileclip_config.json")
