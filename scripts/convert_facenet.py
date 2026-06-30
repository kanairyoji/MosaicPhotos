"""facenet-pytorch の InceptionResnetV1（VGGFace2 学習・MIT）を Core ML(.mlpackage) へ変換する。

- 採用モデル: facenet-pytorch InceptionResnetV1 / pretrained='vggface2'
  - ライセンス: facenet-pytorch は MIT（権利フリー）。モバイル向けで精度も実用域。
  - 入力: 160x160 RGB の**顔切り抜き**。fixed_image_standardization（(x*255-127.5)/128）が必要。
  - 出力: 512 次元の **L2 正規化済み**埋め込み（forward 内で normalize 済み）→ コサイン＝内積。
- アプリ入力経路を CLIP と揃えるため、ImageType は scale=1/255（[0,1]）にし、
  fixed_image_standardization を**モデル内に内包**する（ラッパ）。

出力（OUT 配下）:
  FaceEmbedder.mlpackage   顔埋め込み（[0,1] RGB 入力・正規化内包）
  face_config.json         inputSize / embedDim / model（Swift が参照）
"""
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
from facenet_pytorch import InceptionResnetV1

OUT = sys.argv[1] if len(sys.argv) > 1 else "MosaicPhotos/FaceModel"
INPUT_SIZE = 160
EMBED_DIM = 512

os.makedirs(OUT, exist_ok=True)


class FaceEmbedder(nn.Module):
    """[0,1] RGB（ImageType scale=1/255）を受け、fixed_image_standardization を内包して
    InceptionResnetV1 で 512 次元 L2 正規化埋め込みを返す。"""

    def __init__(self):
        super().__init__()
        self.backbone = InceptionResnetV1(pretrained="vggface2").eval()

    def forward(self, x):  # x: [N,3,160,160] in [0,1]
        # fixed_image_standardization: (x_255 - 127.5) / 128 = (x01 - 0.5) / (128/255)
        x = (x - 0.5) / (128.0 / 255.0)
        return self.backbone(x)  # already L2-normalized inside facenet


model = FaceEmbedder().eval()
example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
with torch.no_grad():
    traced = torch.jit.trace(model, example)

ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, bias=[0, 0, 0])],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,   # 実機 ANE 前提
)
ml.save(os.path.join(OUT, "FaceEmbedder.mlpackage"))
print("saved face embedder")

with open(os.path.join(OUT, "face_config.json"), "w") as f:
    json.dump({"inputSize": INPUT_SIZE, "embedDim": EMBED_DIM,
               "model": "facenet-inceptionresnetv1-vggface2"}, f, indent=2)
print("wrote face_config.json")
