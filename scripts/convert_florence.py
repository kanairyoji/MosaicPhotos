#!/usr/bin/env python3
"""Florence-2-base を Core ML(.mlpackage) + トークナイザ資産へ変換する（VLM キャプション用）。

⚠️ transformers 4.49 + trust_remote_code 前提（build_florence.sh の venv）。手動実行専用。
出力（OUT・既定 MosaicPhotos/VLM/）:
  VLMVision.mlpackage    画像(ImageType scale=1/255・mean/std内包・768)→ encoder_hidden + encoder_mask
  VLMDecoder.mlpackage   decoder_input_ids[1,MAXLEN] + encoder_hidden + encoder_mask → logits[1,MAXLEN,vocab]
  vlm_config.json        Swift ランタイム/トークナイザ用メタ（task/maxLen/特殊トークン等）
  vlm_vocab.json         token→id（byte-level BPE 基本語彙・復号に使用）
  vlm_merges.txt         BPE マージ（GPT2Tokenizer 互換・復号では未使用だが同梱）

設計（PoC=convert_florence_poc.py と対）:
- エンコーダにタスク "<DETAILED_CAPTION>" を焼き込み、画像正規化(mean/std)も内包＝Swift は素の画像を渡すだけ。
- デコーダは固定長 [1,MAXLEN]（動的長は ANE 非対応）。因果マスクで length 以降の PAD は現在位置に無影響。
"""
import os, json, numpy as np, torch, torch.nn as nn
import coremltools as ct
from transformers import AutoProcessor, AutoModelForCausalLM
from transformers.modeling_utils import PreTrainedModel

REPO = "microsoft/Florence-2-base"
TASK = os.environ.get("FLORENCE_TASK", "<DETAILED_CAPTION>")
OUT = os.environ.get("OUT", "MosaicPhotos/VLM")
MAX_NEW = int(os.environ.get("MAX_NEW_TOKENS", "48"))
MAXLEN = MAX_NEW + 2

for a in ("_supports_sdpa", "_supports_flash_attn_2", "_supports_flash_attn"):
    if not hasattr(PreTrainedModel, a):
        setattr(PreTrainedModel, a, False)

os.makedirs(OUT, exist_ok=True)
proc = AutoProcessor.from_pretrained(REPO, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(REPO, trust_remote_code=True,
                                             torch_dtype=torch.float32, attn_implementation="eager").eval()
lm_cfg = model.language_model.config
ip = proc.image_processor
mean = list(ip.image_mean); std = list(ip.image_std)
img_size = int(ip.size["height"])
# ⚠️ task_ids は processor 経由で作る（Florence は "<DETAILED_CAPTION>" を自然文プロンプトへ**展開**する。
#    proc.tokenizer で literal をトークン化するとタスク名をエコーする）。ダミー画像で input_ids だけ取る。
from PIL import Image as _Image
_dummy = _Image.new("RGB", (img_size, img_size))
task_ids = proc(text=TASK, images=_dummy, return_tensors="pt")["input_ids"]  # [1, Ntask]（展開済み）
print("img_size", img_size, "mean", mean, "std", std, "task_ids", tuple(task_ids.shape),
      "dec_start", lm_cfg.decoder_start_token_id, "eos", lm_cfg.eos_token_id, "pad", lm_cfg.pad_token_id)

class Encoder(nn.Module):
    def __init__(s, m, task_ids, mean, std):
        super().__init__(); s.m = m; s.register_buffer("task_ids", task_ids)
        s.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
        s.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))
    def forward(s, x):                                  # x: [0,1] RGB（ImageType scale=1/255）
        x = (x - s.mean) / s.std                        # CLIP 系正規化を内包
        image_features = s.m._encode_image(x)
        task_embeds = s.m.get_input_embeddings()(s.task_ids)
        inputs_embeds, attn = s.m._merge_input_ids_with_image_features(image_features, task_embeds)
        enc = s.m.language_model.get_encoder()(inputs_embeds=inputs_embeds, attention_mask=attn)[0]
        return enc, attn

class DecoderStep(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, decoder_input_ids, encoder_hidden, encoder_mask):
        dec = s.m.language_model.get_decoder()(
            input_ids=decoder_input_ids, encoder_hidden_states=encoder_hidden,
            encoder_attention_mask=encoder_mask)[0]
        return s.m.language_model.lm_head(dec) + s.m.language_model.final_logits_bias

enc_mod = Encoder(model, task_ids, mean, std).eval()
dec_mod = DecoderStep(model).eval()
img01 = torch.rand(1, 3, img_size, img_size)
with torch.no_grad():
    enc_hidden, enc_mask = enc_mod(img01)
print("enc_hidden", tuple(enc_hidden.shape), "enc_mask", tuple(enc_mask.shape))

# ---- Encoder: ImageType(scale=1/255) ----
enc_traced = torch.jit.trace(enc_mod, img01, check_trace=False)
enc_ml = ct.convert(enc_traced,
    inputs=[ct.ImageType(name="image", shape=img01.shape, scale=1 / 255.0, bias=[0, 0, 0])],
    outputs=[ct.TensorType(name="encoder_hidden"), ct.TensorType(name="encoder_mask")],
    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
enc_ml.save(os.path.join(OUT, "VLMVision.mlpackage")); print("saved VLMVision")

# ---- Decoder: 固定長 [1,MAXLEN] ----
PAD = lm_cfg.pad_token_id
dec_ids0 = torch.full((1, MAXLEN), PAD, dtype=torch.int32); dec_ids0[0, 0] = lm_cfg.decoder_start_token_id
dec_traced = torch.jit.trace(dec_mod, (dec_ids0, enc_hidden, enc_mask), check_trace=False)
# encoder_hidden/mask は VLMVision の出力（fp16）をそのまま繋ぐため fp16 入力にする
# （fp32 にすると Swift 側で毎回キャスト copy が要る）。
dec_ml = ct.convert(dec_traced,
    inputs=[ct.TensorType(name="decoder_input_ids", shape=(1, MAXLEN), dtype=np.int32),
            ct.TensorType(name="encoder_hidden", shape=enc_hidden.shape, dtype=np.float16),
            ct.TensorType(name="encoder_mask", shape=enc_mask.shape, dtype=np.float16)],
    outputs=[ct.TensorType(name="logits")],
    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
dec_ml.save(os.path.join(OUT, "VLMDecoder.mlpackage")); print("saved VLMDecoder")

# ---- トークナイザ資産（vocab / merges）＋ config ----
tk = proc.tokenizer
be = json.loads(tk.backend_tokenizer.to_str())
base_vocab = be["model"]["vocab"]              # token -> id（基本語彙）
merges = be["model"].get("merges", [])
added = {a["content"]: a["id"] for a in be.get("added_tokens", [])}   # 特殊/タスク/座標トークン
with open(os.path.join(OUT, "vlm_vocab.json"), "w") as f:
    json.dump(base_vocab, f, ensure_ascii=False)
with open(os.path.join(OUT, "vlm_merges.txt"), "w") as f:
    f.write("\n".join(m if isinstance(m, str) else " ".join(m) for m in merges))
cfg = {
    "model": REPO, "task": TASK, "imageSize": img_size, "maxLen": MAXLEN, "maxNewTokens": MAX_NEW,
    "vocabSize": int(lm_cfg.vocab_size),
    "decoderStartTokenId": int(lm_cfg.decoder_start_token_id),
    "eosTokenId": int(lm_cfg.eos_token_id), "padTokenId": int(PAD),
    "addedTokens": added,
}
with open(os.path.join(OUT, "vlm_config.json"), "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print("wrote vlm_config.json / vlm_vocab.json / vlm_merges.txt")
print("done Florence conversion ->", OUT)
