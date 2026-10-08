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
    print(f"✅ 夜間の枠の手 {len(found) - len(EXEMPT)} 件はすべて早見表にあります"
          f"（裏返しの手 {len(EXEMPT)} 件は本体の行に含む）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
