#!/usr/bin/env python3
"""夜間の枠の手（`NightlyPlan.Step`）が、早見表に全部書かれているかを確かめる。

⚠️ なぜ要るか（ADR-259・実機ログ diagnostics-105）
`background-behavior.md` は「**どの設定だと何が動くか**」の正本で、CLAUDE.md は
「ゲートを足す/変えるたびに更新」と決めている。それでも**クラウド写真の撮影日時の
問い合わせはどちらの表にも載っていなかった**——だから「この処理には背面の駆動役が
無い」ことに誰も気づかず、実機 11 起動・25 時間で **12 枚**しか進んでいなかった
（残り 105,662 枚＝事実上一巡しない）。

表に無いものは**レビューの視界に入らない**。人の注意では守れない（実際に守れなかった）ので、
機械で確かめる。

⚠️ この検査が見つけられるのは「**コードにある手が表に無い**」だけで、
「**あるべき手が無い**」は見つけられない（機能の不在は検査できない）。
後者は「表を見て、駆動役が無い処理を探す」というレビューの手順で補う——
だからこそ表の網羅が要る。

## 使い方
    python3 scripts/check_window_plan_doc.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / "MosaicPhotos/NightlyWorkPolicy.swift"
DOC = ROOT / "docs/architecture-note/records/background-behavior.md"

# `label` の文字列（補間の手前まで）を手の名前として使う。
LABEL = re.compile(r'case \.(\w+)(?:\([^)]*\))?:\s*return "([^"\\(]*)')

# 表に出てこなくてよい手（理由つき）。
EXEMPT = {
    # 「見送り・スキップ」は本体の手の裏返しなので、本体が載っていれば足りる。
    "skipAnalysisBoostActive": "analysis の裏返し（ブースト中は飛ばす＝本体の行に書いてある）",
    "deferGenerate": "generate の裏返し（見送りの条件は generate の行に書いてある）",
    "skipGenerateLowMemory": "generate の裏返し（空きメモリの条件は generate の行に書いてある）",
}


def steps() -> dict[str, str]:
    """case 名 → ログに出る名前。"""
    text = PLAN.read_text(encoding="utf-8")
    return {m.group(1): m.group(2) for m in LABEL.finditer(text)}


def main() -> int:
    if not PLAN.exists() or not DOC.exists():
        print("⚠️ 参照先が見つかりません")
        return 1
    doc = DOC.read_text(encoding="utf-8")
    found = steps()
    if not found:
        print(f"⚠️ {PLAN.name} から手を 1 つも読み取れませんでした（label の形が変わった？）")
        return 1

    missing = []
    for case, label in sorted(found.items()):
        if case in EXEMPT:
            continue
        # ログ名か case 名のどちらかが表のどこかに在ればよい（表現は日本語なので縛らない）。
        if label and label in doc:
            continue
        if case in doc:
            continue
        missing.append((case, label))

    if missing:
        print("❌ 夜間の枠の手が早見表に書かれていません:")
        for case, label in missing:
            print(f"   {case}（ログ名 \"{label}\"）")
        print()
        print(f"   → {DOC.relative_to(ROOT)} の「処理枠（夜間）の手順」と")
        print("     「処理ごとの依存ゲート」に行を足してください。")
        print("     表に無い処理はレビューの視界に入らず、駆動役の抜けに気づけません（ADR-259）。")
        return 1
    rc = check_every_window_column(doc)
    if rc:
        return rc
    print(f"✅ 夜間の枠の手 {len(found) - len(EXEMPT)} 件はすべて早見表にあります"
          f"（裏返しの手 {len(EXEMPT)} 件は本体の行に含む）")
    return 0


def declared_every_window() -> dict[str, bool]:
    """`declaredSpec(for:)` の各 case から `everyWindow:` を読む。

    ⚠️ 既定値は無い（ADR-196 で撤去した）ので、読めない case は**異常**として扱う。
    """
    src = PLAN.read_text(encoding="utf-8")
    start = src.index("private static func declaredSpec(for kind: Kind)")
    body = src[start:src.index("\n    }\n", start)]
    out: dict[str, bool] = {}
    chunks = re.split(r"\n        case \.(\w+):", body)
    # chunks = [前置き, kind1, 本文1, kind2, 本文2, ...]
    for kind, chunk in zip(chunks[1::2], chunks[2::2]):
        m = re.search(r"everyWindow:\s*(true|false)", chunk)
        if m:
            out[kind] = m.group(1) == "true"
    return out


def check_every_window_column(doc: str) -> int:
    """⚠️ 早見表の「毎窓」列が宣言と一致していること（ADR-274 追補 2）。

    なぜ要るか: 列を足したとき**5 行のセルを足し忘れ**、`条件` の文章が「毎窓」列に
    ずれて表示されていた。`label` の存在だけを見るこの検査は素通りした
    ——「並びを 2 か所に書けば必ずずれる」（ADR-273 #2）の `everyWindow` 版。
    """
    declared = declared_every_window()
    if len(declared) < 11:
        print(f"⚠️ `declaredSpec(for:)` から everyWindow を {len(declared)} 件しか読めませんでした"
              "（宣言の書き方が変わった？ 既定値は置かない決め＝ADR-196）")
        return 1

    lines = [l for l in doc.splitlines() if l.startswith("| ") and "`" in l]
    header = next((l for l in doc.splitlines() if l.startswith("| 手 |")), None)
    if header is None or "毎窓" not in header:
        print("❌ 早見表に「毎窓」列がありません（ADR-274 追補 2 で足した列）")
        return 1
    want_cells = len(header.split("|")) - 2
    col = [c.strip() for c in header.split("|")][1:-1].index("**毎窓**" if "**毎窓**" in header
                                                             else "毎窓")

    problems: list[str] = []
    seen: set[str] = set()
    for line in lines:
        cells = [c.strip() for c in line.split("|")][1:-1]
        m = re.search(r"`(\w+)`", cells[0] if cells else "")
        if not m or m.group(1) not in declared:
            continue
        kind = m.group(1)
        seen.add(kind)
        if len(cells) != want_cells:
            problems.append(f"{kind}: セルが {len(cells)} 個（見出しは {want_cells} 個）"
                            "——列を足したときにセルを足し忘れている")
            continue
        # ⚠️ 強調（`**○（ADR-266）**`）を剥がしてから見る——表は人が読むものなので
        #    太字が付く。最初に見つかる ○/✕ で判定する（実際にここで 1 回落ちた）。
        cell = cells[col].lstrip("*").strip()
        if cell.startswith("○"):
            actual = True
        elif cell.startswith("✕"):
            actual = False
        else:
            problems.append(f"{kind}: 「毎窓」のセルが ○/✕ で始まっていない: {cell!r}")
            continue
        if actual != declared[kind]:
            problems.append(f"{kind}: 早見表は {'○' if actual else '✕'} だが "
                            f"宣言は {declared[kind]}")
    for kind in sorted(set(declared) - seen):
        problems.append(f"{kind}: 早見表に行が見つからない（「毎窓」を答えていない）")

    if problems:
        print("❌ 早見表の「毎窓」が宣言と合っていません:")
        for line in problems:
            print(f"   {line}")
        print()
        print(f"   → {DOC.relative_to(ROOT)} の手の性質の表と")
        print(f"     {PLAN.relative_to(ROOT)} の `declaredSpec(for:)` を合わせてください。")
        print("     ⚠️ 「毎窓」は性質から導けない製品の要件なので、**11 の手すべてが答える**"
              "（既定値を置かない＝ADR-196）。")
        return 1
    print(f"✅ 早見表の「毎窓」{len(seen)} 件が宣言と一致しています")
    return 0


if __name__ == "__main__":
    sys.exit(main())
