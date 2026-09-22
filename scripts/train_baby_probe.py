#!/usr/bin/env python3
"""赤ちゃん（0〜2 歳）判定の線形判別器を学習する（ADR-219）。

材料は FairFace（CC BY 4.0・年齢区分に「0〜2 歳」がある）を本番と同じ処理で埋め込んだもの
（`MosaicPhotosTests/FairFaceEmbeddingTests` が `<root>/embeddings-<model>.json` に書く）。
判別器は顔の埋め込み（512 次元）に対するロジスティック回帰＝数値 513 個。アプリに入れるのは
この数値だけで、画像は含まない。

評価は 2 つ:
  - FairFace の検証用分割（学習に使っていない）
  - FG-NET（学術用途のデータ。**評価だけ**に使い、学習には使わない）

しきい値は「赤ちゃんでない顔を赤ちゃんと取り違える率」が `--fpr`（既定 1%）になる位置。
取り違えた大人の顔どうしが「数年離れているので別人」とされると、同じ人が分かれるため、
見逃しより取り違えを少なくする側に寄せる。

使い方:
  python3 scripts/train_baby_probe.py \
    --out ~/DEV/tmp/face-eval-fairface/baby_probe.json \
    --swift Packages/FaceCore/Sources/FaceCore/Faces/BabyProbe+AuraFace.swift
"""
import argparse, csv, json, os
import numpy as np


def load_fairface(root, model):
    emb = json.load(open(os.path.join(root, f"embeddings-{model}.json")))
    rows = list(csv.DictReader(open(os.path.join(root, "labels.csv"))))
    X, y, split = [], [], []
    for r in rows:
        e = emb.get(r["file"])
        if not e or not e.get("embedding"):
            continue
        v = np.array(e["embedding"], np.float32)
        X.append(v / np.linalg.norm(v))
        y.append(1 if int(r["age_group"]) == 0 else 0)   # 0 = "0-2"
        split.append(r["split"])
    return np.array(X), np.array(y), np.array(split)


def load_fgnet(root):
    cache = json.load(open(os.path.join(root, "fgnet", "embeddings-v5.json")))["embeddings"]
    X, age = [], []
    for r in csv.DictReader(open(os.path.join(root, "fgnet", "labels.csv"))):
        e = cache.get(r["file"])
        if not e:
            continue
        v = np.array(e, np.float32)
        X.append(v / np.linalg.norm(v))
        age.append(int(r["age"]))
    return np.array(X), np.array(age)


def train(X, t, l2=1e-3, iters=4000, lr=2.0):
    """件数の偏りを補正したロジスティック回帰（勾配法・決定的）。"""
    w = np.zeros(X.shape[1]); b = 0.0
    weight = np.where(t == 1, 0.5 / t.mean(), 0.5 / (1 - t.mean()))
    for _ in range(iters):
        p = 1 / (1 + np.exp(-(X @ w + b)))
        g = (p - t) * weight
        w -= lr * (X.T @ g / len(t) + l2 * w)
        b -= lr * g.mean()
    return w, b


def auc(pos, neg):
    neg = np.sort(neg)
    return float(np.mean(np.searchsorted(neg, pos)) / len(neg))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fairface", default=os.path.expanduser("~/DEV/tmp/face-eval-fairface"))
    ap.add_argument("--faceeval", default=os.path.expanduser("~/DEV/tmp/face-eval"))
    ap.add_argument("--model", default="auraface-v1-r100")
    ap.add_argument("--fpr", type=float, default=0.01)
    ap.add_argument("--out")
    ap.add_argument("--swift", help="判別器の数値を Swift のファイルとして書き出す")
    args = ap.parse_args()

    X, y, split = load_fairface(args.fairface, args.model)
    tr, va = split == "train", split == "val"
    print(f"FairFace: 学習 {tr.sum()} 顔（赤ちゃん {y[tr].sum()}）・検証 {va.sum()} 顔（赤ちゃん {y[va].sum()}）")
    w, b = train(X[tr], y[tr].astype(float))

    s_va = X[va] @ w + b
    neg = np.sort(s_va[y[va] == 0])
    threshold = float(neg[int(len(neg) * (1 - args.fpr))])
    pos = s_va[y[va] == 1]
    print(f"検証（FairFace）: AUC {auc(pos, neg):.3f}・しきい値 {threshold:.3f}・"
          f"赤ちゃんを見つけた率 {(pos >= threshold).mean() * 100:.1f}%・"
          f"取り違え {(neg >= threshold).mean() * 100:.1f}%")

    Xf, age = load_fgnet(args.faceeval)
    s_f = Xf @ w + b
    baby = age <= 2
    print(f"評価（FG-NET・学習に不使用）: AUC {auc(s_f[baby], s_f[~baby]):.3f}・"
          f"0〜2 歳を見つけた率 {(s_f[baby] >= threshold).mean() * 100:.1f}%・"
          f"3 歳以上を赤ちゃん扱い {(s_f[~baby] >= threshold).mean() * 100:.1f}%")
    for lo, hi in [(0, 0), (1, 1), (2, 2), (3, 3), (4, 5), (6, 9), (10, 19), (20, 99)]:
        m = (age >= lo) & (age <= hi)
        print(f"  {lo}〜{hi} 歳: 赤ちゃん判定 {(s_f[m] >= threshold).mean() * 100:5.1f}%（{m.sum()} 顔）")

    if args.out:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        json.dump({"model": args.model, "source": "FairFace (CC BY 4.0) age group 0-2",
                   "weights": [round(float(v), 6) for v in w], "bias": round(float(b), 6),
                   "threshold": round(threshold, 6), "fpr": args.fpr},
                  open(args.out, "w"))
        print("書き出し:", args.out)
    if args.swift:
        values = ",\n        ".join(", ".join(f"{float(v):.6f}" for v in w[i:i + 8]) for i in range(0, len(w), 8))
        open(args.swift, "w").write(f"""// ⚠️ 生成物: scripts/train_baby_probe.py が書き出す。手で編集しない。
// 学習材料: FairFace（CC BY 4.0・年齢区分「0〜2 歳」）を本番と同じ処理で埋め込んだもの。
// 顔モデル: {args.model}。しきい値は「赤ちゃんでない顔を赤ちゃんと取り違える率」{args.fpr * 100:.0f}%（FairFace 検証用分割）。

extension BabyProbe {{
    /// AuraFace-v1（arcface プロファイル）の埋め込み空間に対する赤ちゃん判定（ADR-219）。
    public static let auraFace = BabyProbe(
        weights: [
        {values}
        ],
        bias: {float(b):.6f},
        threshold: {threshold:.6f})
}}
""")
        print("書き出し:", args.swift)


if __name__ == "__main__":
    main()
