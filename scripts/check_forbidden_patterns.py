#!/usr/bin/env python3
"""**一度「やらない」と決めた書き方**が、別の場所で生き残っていないかを確かめる。

⚠️⚠️ なぜ要るか（2026-09-29 に踏んだ）
ADR-143 が「オフセットで送らない」と決め `AutoAlbumStore` は直したのに、
`DropboxCacheStore.buildItemIndex` だけ `fetchOffset` のまま残っていた。
実機で **1 回 35 秒**の作り直しになり、しかも走査中の挿入で**行が黙って飛ぶ**状態だった。

これは「実機のたびにバグが出る」の**最多の原因**として数え上げた形そのもの——
**同じ規則が複数の場所に散っていて、片方だけ直す**。
⚠️ 規約（CLAUDE.md）に書くだけでは検出しない。**決めたら、ここに 1 行足す。**

## 足し方
`RULES` に (パターン, 理由, 許す場所) を 1 行足す。許す場所は「そこだけは正しい」経路
（記録・テスト・説明）に限る。⚠️ **通すために許可を足したくなったら、それは規則の見直し時**。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (正規表現, なぜ禁じたか, 許す経路の部分一致)
RULES: list[tuple[str, str, tuple[str, ...]]] = [
    (r"\.fetchOffset\s*=",
     "オフセットのページングは O(n²) で、走査中の挿入で行が飛ぶ（ADR-143/239）。"
     "キーセット・ページング（前回の最後より大きいもの）にする。",
     ()),
    (r"\bObservableObject\b",
     "状態は Swift Observation（@Observable）で持つ（CLAUDE.md）。"
     "iOS 26 SDK では Combine の明示 import が要るため使わない。",
     ()),
    (r"^\s*import Combine\b",
     "Combine は使わない（CLAUDE.md・@Observable に統一）。",
     ()),
]

SEARCH = [ROOT / "MosaicPhotos"] + sorted((ROOT / "Packages").glob("*/Sources"))


def main() -> int:
    failed = False
    for pattern, why, allowed in RULES:
        hits = subprocess.run(
            ["grep", "-rnE", "--include=*.swift", pattern, *map(str, SEARCH)],
            capture_output=True, text=True).stdout.splitlines()
        real = []
        for line in hits:
            path = line.split(":", 1)[0]
            # ⚠️ コメント行（「以前は …していた」の説明）は当てない。
            body = line.split(":", 2)[-1].lstrip()
            if body.startswith("//") or body.startswith("///"):
                continue
            if any(a in path for a in allowed):
                continue
            real.append(line)
        if real:
            failed = True
            print(f"❌ 使わないと決めた書き方が残っています: /{pattern}/")
            print(f"   理由: {why}")
            for line in real[:10]:
                print(f"   {line}")
            print()
    if failed:
        print("⚠️ 「同じ規則が複数の場所に散っていて片方だけ直す」は、")
        print("   実機で繰り返し出ている不具合の最多の形です（2026-09-28 に数えた）。")
        return 1
    print(f"✅ 使わないと決めた書き方 {len(RULES)} 件は、どこにも残っていません。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
