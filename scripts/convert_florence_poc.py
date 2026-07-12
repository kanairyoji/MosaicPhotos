#!/usr/bin/env python3
"""Florence-2-base の Core ML 変換 PoC（採用可否の検証専用・手動実行）。

⚠️ transformers 4.49 + trust_remote_code 前提（.vlmbench_flor venv）。CI とは無関係。
やること: (1)画像→encoder隠れ状態 と (2)decoder 1ステップ→logits の2つを Core ML fp16 化し、
          貪欲デコードで HF 参照キャプションと一致するか＋所要時間を確認する。
出力: .vlmbench_flor/florence_coreml/{FlorenceEncoder,FlorenceDecoder}.mlpackage
"""
import os, time, json, numpy as np, torch, torch.nn as nn
import coremltools as ct
from transformers import AutoProcessor, AutoModelForCausalLM
from transformers.modeling_utils import PreTrainedModel
from PIL import Image

REPO = "microsoft/Florence-2-base"
TASK = "<DETAILED_CAPTION>"
OUT = ".vlmbench_flor/florence_coreml"
MAX_NEW = 48
IMG = os.environ.get("IMG", ".mobileclip_build/imagenette/imagenette2-160/val/n03417042/ILSVRC2012_val_00002210.JPEG")

for a in ("_supports_sdpa", "_supports_flash_attn_2", "_supports_flash_attn"):
    if not hasattr(PreTrainedModel, a):
        setattr(PreTrainedModel, a, False)

os.makedirs(OUT, exist_ok=True)
proc = AutoProcessor.from_pretrained(REPO, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(REPO, trust_remote_code=True,
                                             torch_dtype=torch.float32, attn_implementation="eager").eval()
cfg = model.language_model.config
DEC_START = cfg.decoder_start_token_id
EOS = cfg.eos_token_id
PAD = cfg.pad_token_id
print("dec_start", DEC_START, "eos", EOS, "pad", PAD, "d_model", cfg.d_model, "vocab", cfg.vocab_size)

img = Image.open(IMG).convert("RGB")
enc_inputs = proc(text=TASK, images=img, return_tensors="pt")
pixel_values = enc_inputs["pixel_values"]           # [1,3,H,W]
task_ids = enc_inputs["input_ids"]                  # [1, Ntask]
print("pixel", tuple(pixel_values.shape), "task_ids", tuple(task_ids.shape))

# ---- 参照: HF generate ----
with torch.no_grad():
    gen = model.generate(input_ids=task_ids, pixel_values=pixel_values,
                         max_new_tokens=MAX_NEW, num_beams=1, do_sample=False)
ref_text = proc.batch_decode(gen, skip_special_tokens=True)[0].strip()
print("REF:", ref_text)

lm = model.language_model
class Encoder(nn.Module):
    def __init__(s, m, task_ids):
        super().__init__(); s.m = m; s.register_buffer("task_ids", task_ids)
    def forward(s, pixel_values):
        image_features = s.m._encode_image(pixel_values)                 # [1,Nimg,D]
        task_embeds = s.m.get_input_embeddings()(s.task_ids)             # [1,Ntask,D]
        inputs_embeds, attn = s.m._merge_input_ids_with_image_features(image_features, task_embeds)
        enc = s.m.language_model.get_encoder()(inputs_embeds=inputs_embeds, attention_mask=attn)[0]
        return enc, attn                                                 # [1,Nenc,D], [1,Nenc]

class DecoderStep(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, decoder_input_ids, encoder_hidden_states, encoder_attention_mask):
        dec = s.m.language_model.get_decoder()(
            input_ids=decoder_input_ids,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=encoder_attention_mask)[0]
        logits = s.m.language_model.lm_head(dec) + s.m.language_model.final_logits_bias
        return logits                                                    # [1,L,vocab]

enc_mod = Encoder(model, task_ids).eval()
dec_mod = DecoderStep(model).eval()
with torch.no_grad():
    enc_hidden, enc_mask = enc_mod(pixel_values)
print("enc_hidden", tuple(enc_hidden.shape), "enc_mask", tuple(enc_mask.shape))

# ---- trace + convert: Encoder ----
enc_traced = torch.jit.trace(enc_mod, pixel_values, check_trace=False)
enc_ml = ct.convert(enc_traced,
    inputs=[ct.TensorType(name="pixel_values", shape=pixel_values.shape, dtype=np.float32)],
    outputs=[ct.TensorType(name="encoder_hidden"), ct.TensorType(name="encoder_mask")],
    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
enc_ml.save(os.path.join(OUT, "FlorenceEncoder.mlpackage")); print("saved encoder")

# ---- trace + convert: DecoderStep (FIXED length・ANE 対応・SmolVLM と同方式) ----
# 動的長は ANE(Espresso) が拒否するため固定長 [1, MAXLEN] にパディングし、位置 length-1 の
# logits を読む（因果マスクで length 以降の PAD は現在位置に影響しない）。
MAXLEN = MAX_NEW + 2
dec_ids0 = torch.full((1, MAXLEN), PAD, dtype=torch.int32); dec_ids0[0, 0] = DEC_START
dec_traced = torch.jit.trace(dec_mod, (dec_ids0, enc_hidden, enc_mask), check_trace=False)
dec_ml = ct.convert(dec_traced,
    inputs=[ct.TensorType(name="decoder_input_ids", shape=(1, MAXLEN), dtype=np.int32),
            ct.TensorType(name="encoder_hidden", shape=enc_hidden.shape, dtype=np.float32),
            ct.TensorType(name="encoder_mask", shape=enc_mask.shape, dtype=np.float32)],
    outputs=[ct.TensorType(name="logits")],
    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17)
dec_ml.save(os.path.join(OUT, "FlorenceDecoder.mlpackage")); print("saved decoder")

# ---- greedy decode via Core ML + latency ----
def du(p): return sum(os.path.getsize(os.path.join(dp,f)) for dp,_,fs in os.walk(p) for f in fs)/1e6
enc_cm = ct.models.MLModel(os.path.join(OUT, "FlorenceEncoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_NE)
dec_cm = ct.models.MLModel(os.path.join(OUT, "FlorenceDecoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_NE)

def run_once():
    t0 = time.time()
    eo = enc_cm.predict({"pixel_values": pixel_values.numpy().astype(np.float32)})
    eh = eo["encoder_hidden"].astype(np.float32); em = eo["encoder_mask"].astype(np.float32)
    t_enc = time.time() - t0
    buf = np.full((1, MAXLEN), PAD, dtype=np.int32); buf[0, 0] = DEC_START
    ids = [DEC_START]; t_dec = 0.0
    for step in range(MAX_NEW):
        t1 = time.time()
        lo = dec_cm.predict({"decoder_input_ids": buf, "encoder_hidden": eh, "encoder_mask": em})["logits"]
        t_dec += time.time() - t1
        nxt = int(np.argmax(lo[0, step]))   # 位置 step（現在の末尾）の次トークン
        if nxt == EOS: break
        ids.append(nxt); buf[0, step + 1] = nxt
    return ids, t_enc, t_dec

# warmup
run_once()
ids, t_enc, t_dec = run_once()
text = proc.batch_decode(torch.tensor([ids]), skip_special_tokens=True)[0].strip()
print("\nCoreML:", text)
print("MATCH:", text == ref_text)
print(json.dumps({
    "task": TASK, "gen_tokens": len(ids) - 1,
    "encoder_ms": round(t_enc*1000, 1), "decoder_total_ms": round(t_dec*1000, 1),
    "total_ms": round((t_enc+t_dec)*1000, 1),
    "size_MB": {"encoder": round(du(os.path.join(OUT,"FlorenceEncoder.mlpackage"))),
                "decoder": round(du(os.path.join(OUT,"FlorenceDecoder.mlpackage")))},
}, ensure_ascii=False))
