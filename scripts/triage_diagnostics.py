#!/usr/bin/env python3
"""実機の診断ログを**体系的に**見る（見たいものだけ見ない）。

⚠️⚠️ なぜ要るか（2026-09-29 に数えて分かった）
3 回続けて、**そのログで一番遅い処理を調べていなかった**:

    diagnostics-98  上位: candidates.cloudRefs 25.0s / buildItemIndex 23.7s
                    → 私が調べたのは people.load.faces 9.4s
    diagnostics-99  上位: candidates.cloudRefs 34.5s / buildItemIndex 32.0s
                    → 私が調べたのは footprint との相関（しかも誤り）
    diagnostics-100 上位: people.load.tuning 130s / candidates.cloudRefs 38.2s

`candidates.cloudRefs` は 3.7s → 38.2s と **10 倍**に育っていたのに、一度も見ていない。
原因は「直前に考えていたものだけを見る」。⚠️ 注意力では直らないので、**必ず全部を出す**。

## 使い方
    python3 scripts/triage_diagnostics.py <ログ> [前回のログ]

前回のログを渡すと、**育っているもの**（前回比）を先に出す——単発の大きさより
「増えていること」のほうが手掛かりになる（上の 2 件はどちらも育っていた）。
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

SPAN = re.compile(r"PERF ([A-Za-z][A-Za-z0-9.<>_-]*) (\d+(?:\.\d+)?)ms")
FOOT = re.compile(r"footprint=(\d+)MB")
HANG = re.compile(r"PERF hang main=(\d+)ms")
# 待つ人が居ない（背景で長いのは正常な）もの。⚠️ 隠すのではなく**末尾にまとめる**。
BACKGROUND = {"net.longpoll"}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def spans(text: str) -> dict[str, list[float]]:
    out: dict[str, list[float]] = defaultdict(list)
    for name, ms in SPAN.findall(text):
        out[name].append(float(ms))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    text = read(Path(sys.argv[1]))
    now = spans(text)
    before = spans(read(Path(sys.argv[2]))) if len(sys.argv) > 2 else {}

    print(f"■ {Path(sys.argv[1]).name}")
    foots = [int(m) for m in FOOT.findall(text)]
    hangs = [int(m) for m in HANG.findall(text)]
    if foots:
        print(f"  footprint  最大 {max(foots)}MB / 中央 {sorted(foots)[len(foots)//2]}MB")
    print(f"  前面ハング  {len(hangs)} 件" + (f"（最大 {max(hangs)}ms）" if hangs else ""))
    errors = defaultdict(int)
    for line in text.splitlines():
        if "ERROR" in line:
            errors[re.sub(r"[0-9]+", "N", line.split("ERROR", 1)[1])[:70]] += 1
    if errors:
        print("  ERROR:")
        for msg, n in sorted(errors.items(), key=lambda kv: -kv[1])[:5]:
            print(f"    {n:4d} ×{msg}")

    if before:
        print("\n■ 前回より育っているもの（⚠️ ここを先に見る）")
        rows = []
        for name, values in now.items():
            if name in BACKGROUND or not values:
                continue
            old = max(before.get(name, [0]) or [0])
            new = max(values)
            if new >= 1000 and (old == 0 or new > old * 1.5):
                rows.append((new - old, name, old, new))
        for _, name, old, new in sorted(rows, reverse=True)[:10]:
            grew = "新規" if old == 0 else f"{old/1000:.1f}s → {new/1000:.1f}s"
            print(f"  {new/1000:8.1f}s  {name:32s} {grew}")
        if not rows:
            print("  （1 秒を超えて 1.5 倍以上に育ったものは無し）")

    print("\n■ 遅い処理（最大値の順・誰かが待つもの）")
    rows = [(max(v), n, len(v)) for n, v in now.items() if n not in BACKGROUND and v]
    for ms, name, count in sorted(rows, reverse=True)[:12]:
        if ms < 500:
            break
        print(f"  {ms/1000:8.1f}s  {name:32s} ({count} 回)")

    tail = [(max(v), n, len(v)) for n, v in now.items() if n in BACKGROUND and v]
    for ms, name, count in sorted(tail, reverse=True):
        print(f"  {ms/1000:8.1f}s  {name:32s} ({count} 回・待つ人が居ない)")

    print("\n⚠️ 上位に**説明できないもの**が残っていたら、そこで止めずに調べること。")
    print("   3 回続けて「一番遅いもの」を素通りしたのが、見落としの原因だった。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
