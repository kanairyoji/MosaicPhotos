#!/usr/bin/env python3
"""消した名前を指す説明が残っていないか数える。

## なぜ要るか（2026-09-24〜26 のレビューループ）

関数を畳んだり改名したりしたとき、**その名前を説明していたコメントや記録を置き忘れる**
——これを 1 回のレビューで **4 回**繰り返した（`filteredCloudItems` /
`sortedByCaptureDateAscending` / `isAnalysisRunning` / `models released`）。
13 周目に「関数を改名・削除したらコメントと記録も同じ周で数える」と教訓を書いた
**その後で**さらに 2 回やった。⚠️ **教訓を書くだけでは止まらない**ので、手順にする。

害は「読み手が grep しても出てこない」こと。記録は「次に同じ問題に当たった人」のために
あるので、名前が変わったら現在地を指し直さないと役目を果たさない。
実機確認の手順に紛れると、**確認が永久に素通りする**（39 周目に実際に起きた）。

## 何を見るか

- **`Sources/` のコメントに残った参照は誤り** → 見つけたら失敗（exit 1）。
  実装の隣にある `///` は「いまのコード」の説明なので、もう無い名前を指してはいけない。
- **`Tests/` のコメントは、経緯の説明なら正しい** → 一覧を出すだけで失敗にしない。
  「以前は X を確かめていたが、本番が呼ばなくなったので畳んだ」はこのリポジトリの作法
  （`GridSignatureTests` が実例）。⚠️ **これを失敗にすると、残すべき経緯まで消させる**
  ——最初そう書いて、自分の正しいコメントに引っかかった（40 周目）。
- **`docs/` の記録も同じ**（CLAUDE.md「項を消さず状態を追記して経緯を残す」）→ 一覧のみ。

## 使い方

    python3 scripts/check_removed_symbols.py            # origin/main..HEAD
    python3 scripts/check_removed_symbols.py <base>     # <base>..HEAD
    python3 scripts/check_removed_symbols.py --staged   # 索引に載せた分だけ

⚠️ 完全ではない。`--` で始まる行から宣言名を拾うだけなので、文字列リテラルの変更
（ログの文言など）は拾えない。`models released` を取り逃がすのはそのため——
**文言も探したいときは `--literal '<文字列>'` で足す**。
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# 宣言を拾う（func / var / let / enum / struct / class / actor / protocol / typealias / case）。
DECL = re.compile(
    r"\b(?:func|var|let|enum|struct|class|actor|protocol|typealias|case)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)

# あまりに一般的で誤検出になる名前は数えない（宣言名としては実在しても、
# 説明文の中の同じ語を拾ってしまうため）。
TOO_COMMON = {
    "shared", "count", "value", "items", "id", "index", "path", "name", "date",
    "self", "result", "out", "state", "reason", "now", "lock", "log", "current",
}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args],
                          capture_output=True, text=True, check=True).stdout


def removed_symbols(diff: str) -> set[str]:
    """消えた宣言名（同じ diff で足し直されていないものだけ）。"""
    removed: set[str] = set()
    added: set[str] = set()
    for line in diff.splitlines():
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("-"):
            removed |= set(DECL.findall(line))
        elif line.startswith("+"):
            added |= set(DECL.findall(line))
    return {s for s in removed - added if s not in TOO_COMMON and len(s) > 3}


def swift_comment_hits(symbol: str) -> tuple[list[str], list[str]]:
    """Swift のコメント行に残った参照を (Sources, Tests) に分けて返す。

    ⚠️ 分ける理由: `Sources/` の `///` は「いまのコード」の説明なので、もう無い名前を
    指していたら誤り。`Tests/` の「以前は X を確かめていた」は**残すべき経緯**で、
    これを誤りにすると直させてはいけないものを直させる（40 周目に自分で踏んだ）。
    """
    try:
        out = git("grep", "-n", "--", symbol, "*.swift")
    except subprocess.CalledProcessError:
        return [], []
    sources, tests = [], []
    for line in out.splitlines():
        try:
            path, _, text = line.split(":", 2)
        except ValueError:
            continue
        if not text.lstrip().startswith("//"):
            continue
        (tests if "/Tests/" in path else sources).append(line)
    return sources, tests


def doc_hits(symbol: str) -> list[str]:
    try:
        return git("grep", "-n", "--", symbol, "docs/").splitlines()
    except subprocess.CalledProcessError:
        return []


def code_exists(symbol: str) -> bool:
    """宣言としてまだ存在するか（コメント以外の行に出るか）。"""
    try:
        out = git("grep", "-n", "--", symbol, "*.swift")
    except subprocess.CalledProcessError:
        return False
    for line in out.splitlines():
        try:
            _, _, text = line.split(":", 2)
        except ValueError:
            continue
        if not text.lstrip().startswith("//"):
            return True
    return False


def main() -> int:
    args = sys.argv[1:]
    literals = []
    while "--literal" in args:
        i = args.index("--literal")
        literals.append(args[i + 1])
        del args[i:i + 2]

    if args and args[0] == "--staged":
        diff = git("diff", "--cached", "--", "*.swift")
    else:
        base = args[0] if args else "origin/main"
        try:
            diff = git("diff", f"{base}..HEAD", "--", "*.swift")
        except subprocess.CalledProcessError:
            # ⚠️ traceback を出さない。浅いクローン（CI）では比較元が手元に無いことがあり、
            # そこで落ちると**このチェック自体が CI のエラー**になる。
            print(f"比較元 '{base}' が見つかりません。"
                  f"浅いクローンなら先に取得してください（CI は github.event.before を使う）。")
            return 0
        if not diff.strip():
            print(f"'{base}..HEAD' に Swift の差分がありません（比較元が正しいか確認）。")
            return 0

    symbols = sorted(removed_symbols(diff))
    # まだコードに宣言が残っているものは「消していない」＝対象外。
    gone = [s for s in symbols if not code_exists(s)]

    failed = False
    print(f"消えた宣言: {len(gone)} 件（拾った候補 {len(symbols)} 件のうち）")
    for s in gone + literals:
        src, tst = swift_comment_hits(s)
        dc = doc_hits(s)
        if not src and not tst and not dc:
            continue
        print(f"\n■ {s}")
        for h in src:
            print(f"  ⚠️ Sources のコメント（直すこと）: {h}")
            failed = True
        for h in tst:
            print(f"  ・Tests のコメント（経緯なら可）: {h}")
        for h in dc:
            print(f"  ・記録（経緯なら可）: {h}")

    if failed:
        print("\n⚠️ Sources のコメントが、もう無い名前を指しています。"
              "実装の隣の説明は「いまのコード」を説明する場所なので、直してください。")
        return 1
    print("\nSources のコメントに、消した名前を指す参照はありません。"
          "（Tests と記録の参照は、経緯の説明なら残してよい。）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
