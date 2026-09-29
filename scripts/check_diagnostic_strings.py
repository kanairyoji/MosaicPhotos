#!/usr/bin/env python3
"""実機確認の手順が指している診断ログの文字列が、コードに実在するかを確かめる。

⚠️ なぜ要るか（2026-09-27 に踏んだ）
`device-verification.md` の G8 は「`driver: turn=` で交互になっている」と書いてあるのに、
実装を整理する過程で**その行を消して**いた。ログに 0 件なので、実機で 1 晩かけても
**何も確かめられない**——手順が静かに死んでいた。しかも前日に
「ログの文字列を変えたら、それを見る手順も一緒に直す」と記録へ書いた直後だった。

人間の注意では守れない（実際に守れなかった）ので、機械で確かめる。

## 使い方
    python3 scripts/check_diagnostic_strings.py

`device-verification.md` の `<!-- expected-diagnostics -->` に続くフェンスに 1 行 1 文字列で
書いた「手順が頼っているログの断片」を、`Sources/` と `MosaicPhotos/` から探す。
**コメント行は数えない**（説明文だけが残っていても、ログには出ない）。
見つからなければ **失敗**（手順が死んでいる）。

⚠️ 文字列は**補間の手前まで**を書く（`"driver: turn="` のように）。
補間（`\\(...)`）の後ろは grep で当てられない。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs/architecture-note/records/device-verification.md"
MARKER = "<!-- expected-diagnostics -->"


def expected_strings() -> list[str]:
    text = DOC.read_text(encoding="utf-8")
    if MARKER not in text:
        print(f"⚠️ {DOC.name} に {MARKER} がありません（一覧の置き場が無い）")
        sys.exit(1)
    after = text.split(MARKER, 1)[1]
    fence = re.search(r"```[a-zA-Z]*\n(.*?)```", after, re.S)
    if not fence:
        print(f"⚠️ {MARKER} の直後にフェンスがありません")
        sys.exit(1)
    out = []
    for line in fence.group(1).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def main() -> int:
    needles = expected_strings()
    if not needles:
        print("⚠️ 期待する文字列が 1 つも書かれていません")
        return 1
    # ⚠️ テストではなく**出す側**（Sources / アプリ）だけを見る。
    #    テストに書いてあっても、実機のログには出ない。
    haystacks = [ROOT / "MosaicPhotos"] + sorted(
        p for p in (ROOT / "Packages").glob("*/Sources"))
    missing = []
    for needle in needles:
        # ⚠️⚠️ **コメントに書いてあっても「在る」ことにしない**（レビューで見つけた・2026-09-29）。
        # `-rlF`（ファイル名だけ）で数えていたので、`AnalysisDriver.swift` の
        # 「この行を消してはいけない」という**説明文**が当たってしまい、
        # `Diagnostics.mark` 本体を消してもこの検査は通っていた
        # ——**このスクリプトが書かれた理由そのものの退行を、このスクリプトが見逃す**状態だった
        # （同じ露出が `peopleGroups: unresolved members` / `CLIP released` /
        #  `face model released` にもあった）。
        found = subprocess.run(
            ["grep", "-rnF", "--include=*.swift", needle, *map(str, haystacks)],
            capture_output=True, text=True)
        code_hits = [line for line in found.stdout.splitlines()
                     if not line.split(":", 2)[-1].lstrip().startswith("//")]
        if not code_hits:
            missing.append(needle)
    if missing:
        print("❌ 実機確認の手順が指しているのに、コードに無い診断ログ:")
        for needle in missing:
            print(f"   - {needle!r}")
        print()
        print("   手順（device-verification.md）が静かに死んでいます。")
        print("   ログを消した／変えたなら、手順と一覧も一緒に直してください。")
        return 1
    print(f"✅ 実機確認が頼っている診断ログ {len(needles)} 件はすべてコードに在ります。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
