#!/usr/bin/env python3
"""現行 VLM(SmolVLM-256M) と Florence-2-base の自然文キャプション性能を実測比較する。

⚠️ これは Mac 上の PyTorch(MPS/CPU) 実測であり、出荷経路(iPhone ANE / Core ML)の値ではない。
   目的は「2モデルの相対比較」(サイズ・メモリ・処理時間)。手動実行専用・CI とは無関係。

各モデルは別プロセスで測ること(peak RSS を分離するため)。使い方:
  python scripts/bench_vlm.py --model smolvlm  --device mps --runs 5 --image <path>
  python scripts/bench_vlm.py --model florence --device mps --runs 5 --image <path>
"""
import argparse, json, resource, time, gc
from pathlib import Path

def rss_mb():
    # macOS の ru_maxrss は bytes。プロセスのピーク常駐を返す。
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

def params_millions(model):
    return sum(p.numel() for p in model.parameters()) / 1e6

def hf_cache_size_mb(repo):
    # ~/.cache/huggingface/hub のスナップショット実体(safetensors 等)の合計。
    base = Path.home() / ".cache/huggingface/hub"
    name = "models--" + repo.replace("/", "--")
    d = base / name
    if not d.exists():
        return None
    total = sum(f.stat().st_size for f in d.rglob("*") if f.is_file() and not f.is_symlink())
    return total / (1024 * 1024)

def bench_smolvlm(image_path, device, runs, max_new_tokens):
    import torch
    from transformers import AutoProcessor, AutoModelForImageTextToText
    from PIL import Image
    repo = "HuggingFaceTB/SmolVLM-256M-Instruct"
    rss_before = rss_mb()
    t0 = time.time()
    proc = AutoProcessor.from_pretrained(repo)
    model = AutoModelForImageTextToText.from_pretrained(repo, torch_dtype=torch.float32)
    model.to(device).eval()
    load_s = time.time() - t0
    img = Image.open(image_path).convert("RGB")
    # アプリと同じ狙い: 1文で主被写体/シーン/人物有無を説明。
    prompt = ("Describe this photo in one short sentence: main subjects, "
              "the scene, and whether any people are visible.")
    messages = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]}]
    chat = proc.apply_chat_template(messages, add_generation_prompt=True)

    def one():
        inputs = proc(text=chat, images=[img], return_tensors="pt").to(device)
        with torch.no_grad():
            out = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False)
        gen = out[0][inputs["input_ids"].shape[1]:]
        text = proc.decode(gen, skip_special_tokens=True).strip()
        return text, gen.shape[0]

    return _time_runs(one, device, runs, params_millions(model), load_s, rss_before,
                      hf_cache_size_mb(repo), {"CAPTION": None})

def bench_florence(image_path, device, runs, max_new_tokens):
    import torch
    from transformers import AutoProcessor, AutoModelForCausalLM
    from transformers.modeling_utils import PreTrainedModel
    from PIL import Image
    # Florence-2 の remote code は旧 transformers 向けで、4.5x では基底クラスに
    # _supports_sdpa 等が無く attn 実装判定で落ちる。既定値を注入して回避する。
    for attr in ("_supports_sdpa", "_supports_flash_attn_2", "_supports_flash_attn"):
        if not hasattr(PreTrainedModel, attr):
            setattr(PreTrainedModel, attr, False)
    repo = "microsoft/Florence-2-base"
    rss_before = rss_mb()
    t0 = time.time()
    proc = AutoProcessor.from_pretrained(repo, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(repo, trust_remote_code=True,
                                                 torch_dtype=torch.float32,
                                                 attn_implementation="eager")
    model.to(device).eval()
    load_s = time.time() - t0
    img = Image.open(image_path).convert("RGB")

    def make(task):
        def one():
            inputs = proc(text=task, images=img, return_tensors="pt").to(device)
            with torch.no_grad():
                out = model.generate(input_ids=inputs["input_ids"],
                                     pixel_values=inputs["pixel_values"],
                                     max_new_tokens=max_new_tokens, do_sample=False, num_beams=1)
            gen = out[0][inputs["input_ids"].shape[1]:]
            text = proc.batch_decode(out, skip_special_tokens=True)[0].strip()
            return text, gen.shape[0]
        return one

    # 自然文キャプション: <CAPTION>(短文) と <DETAILED_CAPTION>(現行 SmolVLM に近い1文詳細)。
    tasks = {"CAPTION": make("<CAPTION>"), "DETAILED_CAPTION": make("<DETAILED_CAPTION>")}
    return _time_runs_multi(tasks, device, runs, params_millions(model), load_s, rss_before,
                            hf_cache_size_mb(repo))

def _sync(device):
    import torch
    if device == "mps":
        torch.mps.synchronize()

def _time_one_task(fn, device, runs):
    # ウォームアップ2回(遅延初期化/コンパイルを除外)。
    for _ in range(2):
        text, ntok = fn()
    _sync(device)
    times = []
    for _ in range(runs):
        t = time.time(); text, ntok = fn(); _sync(device)
        times.append(time.time() - t)
    times.sort()
    mean = sum(times) / len(times)
    return {"sample": text, "gen_tokens": int(ntok),
            "latency_s_mean": round(mean, 3), "latency_s_min": round(times[0], 3),
            "ms_per_token": round(mean / max(ntok, 1) * 1000, 1)}

def _time_runs(fn, device, runs, params, load_s, rss_before, cache_mb, _tasks):
    r = _time_one_task(fn, device, runs)
    return {"params_M": round(params, 1), "hf_cache_MB": None if cache_mb is None else round(cache_mb),
            "load_s": round(load_s, 2), "rss_before_MB": round(rss_before),
            "rss_peak_MB": round(rss_mb()), "tasks": {"CAPTION": r}}

def _time_runs_multi(tasks, device, runs, params, load_s, rss_before, cache_mb):
    out = {}
    for name, fn in tasks.items():
        out[name] = _time_one_task(fn, device, runs)
    return {"params_M": round(params, 1), "hf_cache_MB": None if cache_mb is None else round(cache_mb),
            "load_s": round(load_s, 2), "rss_before_MB": round(rss_before),
            "rss_peak_MB": round(rss_mb()), "tasks": out}

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=["smolvlm", "florence"])
    ap.add_argument("--device", default="mps", choices=["mps", "cpu"])
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--max-new-tokens", type=int, default=48)
    ap.add_argument("--image", required=True)
    a = ap.parse_args()
    fn = bench_smolvlm if a.model == "smolvlm" else bench_florence
    res = fn(a.image, a.device, a.runs, a.max_new_tokens)
    res["model"] = a.model
    res["device"] = a.device
    print("RESULT " + json.dumps(res, ensure_ascii=False))
