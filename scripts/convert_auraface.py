"""AuraFace-v1（fal/AuraFace-v1・Apache 2.0）を Core ML(.mlpackage) へ変換する（ADR-70）。

- 採用モデル: AuraFace-v1（ArcFace 系 ResNet100・**学習データも商用可**・Apache 2.0）
  - 台帳の P5（ADR-56）で「ArcFace 級で許諾的ライセンスの重みは存在しない」として保留だった
    欠落ピース。AGEDB 96.10（本家 ArcFace 98.38）＝**年齢差に強い**のが採用動機
    （facenet の FG-NET TAR@FAR1% は 48.1% で、年齢不変性が現行の主弱点）。
  - 入力: 112x112 RGB の **ArcFace 5 点整列済み**顔切り抜き。(x-127.5)/127.5 正規化。
  - 出力: 512 次元埋め込み（**未正規化**なのでラッパで L2 正規化する）。
- 配布形式は ONNX（insightface 形式 glintr100.onnx）。coremltools は ONNX を直接受けないため
  **onnx2torch** で PyTorch 化してから変換する。変換後に onnxruntime と突き合わせて検証する。
- アプリ入力経路は CLIP/facenet と同じ ImageType scale=1/255（[0,1]）とし、正規化はモデル内に内包。
- ファイル名は互換のため **FaceEmbedder.mlpackage** に据え置く（Swift 側のコード生成名が変わらない）。

出力（OUT 配下）:
  FaceEmbedder.mlpackage   顔埋め込み（[0,1] RGB 入力・正規化内包・L2 正規化出力）
  face_config.json         inputSize/embedDim/model/alignment/pipelineVersion（Swift が参照）
"""
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
import onnx
import onnxruntime as ort
from onnx2torch import convert as onnx_to_torch

WORK = sys.argv[1]
OUT = sys.argv[2]
ONNX_PATH = os.path.join(WORK, "glintr100.onnx")
INPUT_SIZE = 112
EMBED_DIM = 512
PIPELINE_VERSION = 5   # v5: AuraFace + 5 点整列（版上げ＝全再スキャン・名前は持ち越し）

os.makedirs(OUT, exist_ok=True)


class FaceEmbedder(nn.Module):
    """[0,1] RGB（ImageType scale=1/255）→ (x-0.5)/0.5 正規化 → AuraFace → L2 正規化 512 次元。"""

    def __init__(self, backbone: nn.Module):
        super().__init__()
        self.backbone = backbone

    def forward(self, x):  # x: [N,3,112,112] in [0,1]
        # ArcFace 標準の (x_255 - 127.5) / 127.5 = (x01 - 0.5) / 0.5
        x = (x - 0.5) / 0.5
        e = self.backbone(x)
        return nn.functional.normalize(e, dim=1)   # コサイン＝内積にする（facenet と同じ規約）


print("==> ONNX を PyTorch 化")
backbone = onnx_to_torch(onnx.load(ONNX_PATH)).eval()
model = FaceEmbedder(backbone).eval()

example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
with torch.no_grad():
    traced = torch.jit.trace(model, example)

print("==> onnxruntime と突き合わせ検証")
sess = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
input_name = sess.get_inputs()[0].name
x01 = np.random.rand(1, 3, INPUT_SIZE, INPUT_SIZE).astype(np.float32)
ref = sess.run(None, {input_name: (x01 - 0.5) / 0.5})[0]
ref = ref / np.linalg.norm(ref, axis=1, keepdims=True)
with torch.no_grad():
    got = model(torch.from_numpy(x01)).numpy()
cos = float((ref * got).sum())
print(f"    cos(onnxruntime, torch) = {cos:.6f}")
assert cos > 0.999, "ONNX→PyTorch 変換の出力が一致しない"

print("==> Core ML へ変換（FLOAT16・ANE 前提）")
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, bias=[0, 0, 0])],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
ml.save(os.path.join(OUT, "FaceEmbedder.mlpackage"))
print("saved FaceEmbedder.mlpackage (AuraFace-v1)")

with open(os.path.join(OUT, "face_config.json"), "w") as f:
    json.dump({"inputSize": INPUT_SIZE, "embedDim": EMBED_DIM,
               "model": "auraface-v1-r100",
               "alignment": "arcface5",
               "tuning": "arcface",
               "pipelineVersion": PIPELINE_VERSION}, f, indent=2)
print("wrote face_config.json (alignment=arcface5, pipelineVersion=%d)" % PIPELINE_VERSION)
