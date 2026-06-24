#!/usr/bin/env python3
"""MobileCLIP-S2 の画像/テキストエンコーダを Core ML(.mlpackage) へ変換する。

build_mobileclip.sh から呼ばれる（環境変数 CKPT, OUT を使用）。
MobileCLIP の前処理は Resize→CenterCrop→ToTensor のみ（mean/std 正規化なし・[0,1] 入力）。
そのため画像は ImageType の scale=1/255 で [0,1] にするだけでよく、mean/std は適用しない。
"""
import json
import os

import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
import mobileclip

CKPT = os.environ["CKPT"]
OUT = os.environ["OUT"]
CONTEXT_LENGTH = 77

print("loading model:", CKPT)
model, _, preprocess = mobileclip.create_model_and_transforms("mobileclip_s2", pretrained=CKPT)
model.eval()

# 入力サイズを preprocess（Resize/CenterCrop）から取得
img_size = 256
for t in getattr(preprocess, "transforms", []):
    size = getattr(t, "size", None)
    if isinstance(size, int):
        img_size = size
    elif isinstance(size, (tuple, list)) and size:
        img_size = size[0]
print("image input size:", img_size)


class ImageEncoder(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):  # x: [0,1] RGB（MobileCLIP は mean/std 正規化を行わない）
        f = self.m.encode_image(x)
        return f / f.norm(dim=-1, keepdim=True)


class TextEncoder(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, tokens):  # tokens: int32 [1,77]
        f = self.m.encode_text(tokens)
        return f / f.norm(dim=-1, keepdim=True)


# --- 画像エンコーダ ---
img_example = torch.rand(1, 3, img_size, img_size)
img_traced = torch.jit.trace(ImageEncoder(model), img_example)
embed_dim = int(img_traced(img_example).shape[-1])
print("embedding dim:", embed_dim)

img_ml = ct.convert(
    img_traced,
    inputs=[ct.ImageType(name="image", shape=img_example.shape, scale=1 / 255.0, bias=[0, 0, 0])],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
    # ⚠️ 既定の FLOAT16 だと画像タワー（conv/transformer ハイブリッド）がシミュレータで
    # 数値オーバーフローし、埋め込みが全 NaN になる。FLOAT32 で変換して回避する。
    compute_precision=ct.precision.FLOAT32,
)
img_ml.save(os.path.join(OUT, "MobileCLIPImageS2.mlpackage"))
print("saved image encoder")

# --- テキストエンコーダ ---
txt_example = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.int32)
txt_traced = torch.jit.trace(TextEncoder(model), txt_example)
txt_ml = ct.convert(
    txt_traced,
    inputs=[ct.TensorType(name="text", shape=(1, CONTEXT_LENGTH), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
)
txt_ml.save(os.path.join(OUT, "MobileCLIPTextS2.mlpackage"))
print("saved text encoder")

# --- Swift 側が参照する設定 ---
with open(os.path.join(OUT, "mobileclip_config.json"), "w") as f:
    json.dump({"imageSize": img_size, "contextLength": CONTEXT_LENGTH, "embedDim": embed_dim}, f, indent=2)
print("wrote mobileclip_config.json")
