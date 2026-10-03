#!/usr/bin/env python3
"""「重い処理をやるか」を決める純ロジック（ゲート）が、台帳に書かれているかを確かめる。

⚠️ なぜ要るか（ADR-251・ADR-252）
判断を純 enum へ出して規則をテストするのは良い方法で、**規則そのものは一度も間違えていない**。
間違いは必ずその外側で起きた——とくに **材料**（入力）だった。

- ADR-250: `CandidateEnumerationGate` の `cloudRevision` が撮影日の問い合わせでも進むので、
  ゲートが実機で **1 回も効かなかった**（規則も取り出し方も「正しく」書けていた）。
- ADR-252: 夜間の窓が `faceBacklog ?? scanProgressRemaining` と書いていて、
  「分からない」が静かに 0（＝終わった）になっていた。ADR-207 で**自分が禁じた**丸め方。

⚠️⚠️ 純ロジックのテストはこの穴を**原理的に見つけられない**。材料は引数で与えられるので、
「その引数が現実にどう動くか」はテストの外にある。だから「材料に何を期待しているか」を
台帳（`docs/architecture-note/records/gates.md`）に書き、ここで機械的に突き合わせる。

## 使い方
    python3 scripts/check_gate_ledger.py

`Sources/` と `MosaicPhotos/` から判断の純 enum（`*Gate` / `*Policy` / `*Turn`）を集め、
台帳に `## <名前>` の項があるか確かめる。無ければ **失敗**。
ゲートでないもの（設定の列挙・状態の写しなど）は台帳の `<!-- not-gates -->` に
**理由つきで**並べる＝そこに書く手間が「これは判断か？」を一度考えさせる。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs/architecture-note/records/gates.md"
NOT_GATES_MARKER = "<!-- not-gates -->"

# 判断の純ロジックの命名（この 3 つで統一してある）。
DECL = re.compile(r"^[ \t]*(?:public )?enum ([A-Za-z][A-Za-z0-9]*(?:Gate|Policy|Turn))\b")
# 台帳に載せてよいのは「コードに実在する enum」全部（`NightlyPlan` のように命名が
# 揃っていない判断も手で足せる）。取り残された項を見つけるのに使う。
ANY_ENUM = re.compile(r"^(?:public )?enum ([A-Za-z][A-Za-z0-9]*)\b")

SEARCH_DIRS = ["Packages", "MosaicPhotos"]
SKIP_PARTS = ("/.build/", "/Tests/", "/.swiftpm/")


def declared_gates() -> tuple[dict[str, str], set[str]]:
    """(ゲート名 → 宣言のある場所, トップレベル enum の全名前)"""
    found: dict[str, str] = {}
    every: set[str] = set()
    for base in SEARCH_DIRS:
        for path in sorted((ROOT / base).rglob("*.swift")):
            rel = str(path.relative_to(ROOT))
            if any(part in f"/{rel}" for part in SKIP_PARTS):
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeDecodeError):
                continue
            for n, line in enumerate(lines, 1):
                # ⚠️ 入れ子の enum（`case` の種類など）は判断ではない。
                #    インデントのある宣言は除く（トップレベルだけ見る）。
                if line.startswith((" ", "\t")):
                    continue
                if a := ANY_ENUM.match(line):
                    every.add(a.group(1))
                if m := DECL.match(line):
                    found.setdefault(m.group(1), f"{rel}:{n}")
    return found, every


def ledger_entries() -> tuple[set[str], set[str]]:
    """(台帳に項がある名前, ゲートではないと宣言された名前)"""
    if not LEDGER.exists():
        print(f"⚠️ 台帳がありません: {LEDGER.relative_to(ROOT)}")
        sys.exit(1)
    text = LEDGER.read_text(encoding="utf-8")

    body, _, tail = text.partition(NOT_GATES_MARKER)
    entries = set(re.findall(r"^## ([A-Za-z][A-Za-z0-9]*)", body, re.M))

    exempt: set[str] = set()
    if tail:
        fence = re.search(r"```[a-zA-Z]*\n(.*?)```", tail, re.S)
        if fence:
            for line in fence.group(1).splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # 形式: `<名前> — <理由>`（理由は必須＝考えた跡を残す）
                name, sep, reason = line.partition("—")
                if not sep or not reason.strip():
                    print(f"⚠️ not-gates の行に理由がありません: {line}")
                    sys.exit(1)
                exempt.add(name.strip().strip("`"))
    return entries, exempt


def main() -> int:
    gates, every_enum = declared_gates()
    entries, exempt = ledger_entries()

    missing = {name: where for name, where in gates.items()
               if name not in entries and name not in exempt}
    # 台帳にあるのにコードから消えたもの（整理のとき台帳が取り残される）。
    stale = sorted(entries - every_enum)
    # ゲートでないと宣言したのに、もう存在しないもの。
    stale_exempt = sorted(exempt - every_enum)

    if missing:
        print("❌ 台帳に無いゲートがあります（材料の約束が書かれていない）:")
        for name in sorted(missing):
            print(f"   {name}  ({missing[name]})")
        print()
        print(f"   → {LEDGER.relative_to(ROOT)} に `## {sorted(missing)[0]}` の項を足し、")
        print("     材料・材料に求める性質・その性質を守るテストを 1 行ずつ書いてください。")
        print(f"     判断ではない（設定の列挙・状態の写し等）なら {NOT_GATES_MARKER} に理由つきで。")
    if stale:
        print("❌ 台帳にあるのにコードに無いゲート（整理で取り残された項）:")
        for name in stale:
            print(f"   {name}")
    if stale_exempt:
        print("❌ not-gates に書かれているのにコードに無い名前:")
        for name in stale_exempt:
            print(f"   {name}")

    if missing or stale or stale_exempt:
        return 1
    print(f"✅ ゲート {len(gates)} 件すべてが台帳にあります"
          f"（項 {len(entries)} / 判断でないもの {len(exempt)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
