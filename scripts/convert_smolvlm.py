#!/usr/bin/env python3
"""SmolVLM-256M-Instruct（Apache-2.0）→ Core ML 変換。

設計（オンデバイス実行を単純にする割り切り）:
- 視覚: SigLIP + connector（pixel shuffle + 射影）を 1 つの mlpackage に（画像 → 画像トークン埋め込み）。
- 言語: デコーダは **KV キャッシュ無しの固定長（SEQ_LEN）全系列 forward**。生成の各ステップで
  全系列を流し、末尾位置の logits から次トークンを貪欲に選ぶ。O(n^2) だが 135M・短い出力
  （キャプション ~48 トークン）なら ANE で ~1〜2 秒/枚＝夜間バッチには十分。
  状態付き（KV）変換より桁違いに壊れにくく、検証もしやすい。
- 埋め込み行列は .bin（fp16）で書き出し、Swift 側でトークン→埋め込みをルックアップして
  <image> 位置に視覚埋め込みを差し込む（デコーダ入力は inputs_embeds）。

使い方: convert_smolvlm.py <出力dir> [--work <作業dir>]
"""
import argparse
import json
import os
import struct
import sys
from pathlib import Path

import numpy as np
import torch

MODEL_ID = "HuggingFaceTB/SmolVLM-256M-Instruct"
SEQ_LEN = 256          # デコーダ固定長（プロンプト ~90 + 画像 64 + 生成 48 に十分）
MAX_NEW_TOKENS = 48    # Swift 側の既定（config に書き出すだけ）
CAPTION_PROMPT = (
    "Describe this photo in one short sentence: main subjects, the scene, "
    "and whether any people are visible."
)


def log(msg: str) -> None:
    print(f"    {msg}", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--work", default=".smolvlm_build")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    import coremltools as ct
    from transformers import AutoModelForVision2Seq, AutoProcessor

    print("==> モデルをダウンロード/ロード（初回 ~1GB）")
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    model = AutoModelForVision2Seq.from_pretrained(MODEL_ID, torch_dtype=torch.float32)
    model.eval()

    cfg = model.config
    hidden = cfg.text_config.hidden_size
    vocab = cfg.text_config.vocab_size
    image_size = cfg.vision_config.image_size
    # 画像 1 枚 → 何トークンになるか（pixel shuffle 後）。設定から決定的に計算。
    patches = (image_size // cfg.vision_config.patch_size) ** 2
    image_seq_len = patches // (cfg.scale_factor**2)
    log(f"hidden={hidden} vocab={vocab} image={image_size}px image_seq_len={image_seq_len}")

    tok = processor.tokenizer
    image_token_id = tok.convert_tokens_to_ids("<image>")
    fake_image_token_id = tok.convert_tokens_to_ids("<fake_token_around_image>")
    global_img_token_id = tok.convert_tokens_to_ids("<global-img>")
    end_of_utterance_id = tok.convert_tokens_to_ids("<end_of_utterance>")

    # ---- 1) 視覚タワー（SigLIP + connector）----------------------------------
    print("==> 視覚タワーを変換")

    class VisionWrapper(torch.nn.Module):
        """Idefics3 の可変アスペクト位置埋め込みは torch.bucketize を使い CoreML 変換不可。
        固定 512px・マスク無しでは位置 ID は 0..N-1 の連番に確定するため、embeddings を
        手展開して bucketize を迂回する（数値は同一）。"""

        def __init__(self, m):
            super().__init__()
            vm = m.model.vision_model
            self.patch_embedding = vm.embeddings.patch_embedding
            self.position_embedding = vm.embeddings.position_embedding
            self.encoder = vm.encoder
            self.post_layernorm = vm.post_layernorm
            self.connector = m.model.connector
            side = m.config.vision_config.image_size // m.config.vision_config.patch_size
            self.register_buffer("pos_ids", torch.arange(side * side), persistent=False)

        def forward(self, pixel_values):
            # 入力は [0,1]（ImageType scale=1/255）。SigLIP 正規化（mean/std 0.5）を内包する。
            x = (pixel_values - 0.5) / 0.5
            patches = self.patch_embedding(x)                    # (1, dim, 32, 32)
            embeds = patches.flatten(2).transpose(1, 2)          # (1, 1024, dim)
            h = embeds + self.position_embedding(self.pos_ids)   # 固定連番＝フル画像のときの bucketize と同値
            h = self.encoder(inputs_embeds=h).last_hidden_state
            h = self.post_layernorm(h)
            return self.connector(h)   # (1, image_seq_len, hidden)

    vision = VisionWrapper(model).eval()
    example = torch.rand(1, 3, image_size, image_size)
    with torch.no_grad():
        vout = vision(example)
    log(f"vision out: {tuple(vout.shape)}")
    traced_v = torch.jit.trace(vision, example)
    mlv = ct.convert(
        traced_v,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1.0 / 255.0)],
        outputs=[ct.TensorType(name="image_embeds", dtype=np.float16)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    # 視覚エンコーダのみ INT8 重み量子化（既定 ON・179→~90MB）。出力は連続ベクトル（画像埋め込み）で
    # 量子化に強く、fp16 との一致は cos≈0.999＝実質無害。デコーダ（言語 LM）は次単語の argmax が
    # 量子化に敏感（fp16 と一致26%）なので fp16 のまま残す（ADR-32 / model-evaluations 参照）。
    if os.environ.get("QUANTIZE_VISION", "int8").lower() == "int8":
        import coremltools.optimize.coreml as cto
        qcfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", weight_threshold=512))
        mlv = cto.linear_quantize_weights(mlv, qcfg)
        log("vision encoder quantized to INT8 (~half size, cos≈0.999)")
    mlv.save(str(out / "VLMVision.mlpackage"))

    # ---- 2) デコーダ（inputs_embeds 固定長 → logits）--------------------------
    print("==> デコーダを変換（固定長・KVキャッシュ無し）")

    class DecoderWrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.text = m.model.text_model
            self.lm_head = m.lm_head

        def forward(self, inputs_embeds):
            # attention_mask=None → 因果マスクのみ（pad は末尾＝因果マスクで前方に影響しない）。
            hs = self.text(inputs_embeds=inputs_embeds).last_hidden_state
            return self.lm_head(hs)   # (1, SEQ_LEN, vocab)

    dec = DecoderWrapper(model).eval()
    dexample = torch.zeros(1, SEQ_LEN, hidden)
    with torch.no_grad():
        dout = dec(dexample)
    log(f"decoder out: {tuple(dout.shape)}")
    traced_d = torch.jit.trace(dec, dexample)
    mld = ct.convert(
        traced_d,
        inputs=[ct.TensorType(name="inputs_embeds", shape=dexample.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="logits", dtype=np.float16)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    mld.save(str(out / "VLMDecoder.mlpackage"))

    # ---- 3) 埋め込み行列・トークナイザ・設定 -----------------------------------
    print("==> 埋め込み行列とトークナイザ資材を書き出し")
    embed = model.model.text_model.embed_tokens.weight.detach().to(torch.float16).numpy()
    assert embed.shape == (vocab, hidden), embed.shape
    (out / "vlm_embed_tokens.bin").write_bytes(embed.tobytes())
    log(f"embed_tokens: {embed.shape} fp16 = {embed.nbytes / 1e6:.0f}MB")

    # GPT2 系 BPE の vocab/merges（Swift 側トークナイザ用）。tokenizer.json から抽出。
    tj = json.loads(tok.backend_tokenizer.to_str())
    bpe_model = tj["model"]
    (out / "vlm_vocab.json").write_text(json.dumps(bpe_model["vocab"], ensure_ascii=False))
    merges = bpe_model["merges"]
    merge_lines = [" ".join(m) if isinstance(m, list) else m for m in merges]
    (out / "vlm_merges.txt").write_text("\n".join(merge_lines))
    # added tokens（<image> 等の特殊トークン）も語彙に含める。
    added = {t["content"]: t["id"] for t in tj.get("added_tokens", [])}

    # プロンプト（chat template 適用済みの前半/後半に分割して Swift で連結）。
    # <image> の並び: <fake_token_around_image><global-img><image>*N<fake_token_around_image>
    prefix_text = f"<|im_start|>User:"
    suffix_text = f"{CAPTION_PROMPT}<end_of_utterance>\nAssistant:"
    config = {
        "model": MODEL_ID,
        "license": "Apache-2.0",
        "hiddenSize": hidden,
        "vocabSize": vocab,
        "seqLen": SEQ_LEN,
        "maxNewTokens": MAX_NEW_TOKENS,
        "imageSize": image_size,
        "imageSeqLen": image_seq_len,
        "imageTokenId": image_token_id,
        "fakeImageTokenId": fake_image_token_id,
        "globalImgTokenId": global_img_token_id,
        "endOfUtteranceId": end_of_utterance_id,
        "eosTokenId": tok.eos_token_id,
        "bosTokenId": tok.bos_token_id,
        "promptPrefix": prefix_text,
        "promptSuffix": suffix_text,
        "addedTokens": added,
    }
    (out / "vlm_config.json").write_text(json.dumps(config, indent=2, ensure_ascii=False))

    # ---- 4) 検証（PyTorch と CoreML の一致・貪欲1トークン）----------------------
    print("==> 変換検証（1 トークン生成の一致確認）")
    ids = tok(f"{prefix_text}hello", return_tensors="pt").input_ids[0].tolist()
    emb = torch.tensor(embed[ids].astype(np.float32)).unsqueeze(0)
    pad = torch.zeros(1, SEQ_LEN - emb.shape[1], hidden)
    dec_in = torch.cat([emb, pad], dim=1)
    with torch.no_grad():
        ref = dec(dec_in)[0, len(ids) - 1].argmax().item()
    got = mld.predict({"inputs_embeds": dec_in.numpy().astype(np.float16)})["logits"][0, len(ids) - 1].argmax()
    log(f"next-token: torch={ref} coreml={int(got)} {'OK' if ref == int(got) else 'MISMATCH!'}")
    if ref != int(got):
        sys.exit("検証失敗: PyTorch と CoreML の出力が一致しません")

    print("==> 変換完了")


if __name__ == "__main__":
    main()
