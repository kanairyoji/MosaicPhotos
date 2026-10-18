#!/usr/bin/env python3
"""シェルスクリプトで、多バイト文字の直前の変数が `${VAR}` で囲われているかを確かめる（CI）。

macOS 既定の bash 3.2 は、`"…（$VAR）…"` の `）` の先頭バイトを**変数名の一部として食う**。
`VAR\\xef` という別の変数になり、`set -u` の下では `unbound variable` で落ち、無ければ黙って空になる。
`bash -n`（構文チェック）は通るので、**踏むまで気づけない**。

⚠️ 実際に踏んだ（2026-10-18）: `scripts/test.sh` の失敗表示の行が落ちて、肝心の
「どのテストが落ちたか」が出なかった。同じ日に別の道具でも同じ書き間違いを入れ、
そちらは検査が止めた——この検査が無い側だけ素通りした。既存の build_mobileclip.sh にも 4 か所あった。

対象: git が追う *.sh と、bash / sh の shebang を持つファイル。
"""
import re
import subprocess
import sys

UNBRACED_BEFORE_MULTIBYTE = re.compile(r'(?<!\{)\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')

# 当たるべき見本／当たってはいけない見本（規則が生きている証拠・ADR-253）。
MUST_MATCH = ['echo "失敗（$bundle）"', 'echo "OpenCLIP $OC_PRETRAINED・QUANTIZE"']
MUST_NOT_MATCH = ['echo "失敗（${bundle}）"', 'echo "件数 $COUNT 件"', "echo '$HOME'x"]


def shell_files():
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    for path in out:
        try:
            head = open(path, "rb").read(64)
        except OSError:
            continue
        if path.endswith(".sh") or re.match(rb"#!\s*/(usr/)?bin/(env\s+)?(ba)?sh\b", head):
            yield path


def main():
    broken = [s for s in MUST_MATCH if not UNBRACED_BEFORE_MULTIBYTE.search(s)]
    broken += [s for s in MUST_NOT_MATCH if UNBRACED_BEFORE_MULTIBYTE.search(s)]
    if broken:
        print("検査そのものが壊れている（見本の判定が期待と違う）:", *broken, sep="\n  ")
        return 1
    files = list(shell_files())
    if not files:
        print("検査対象なし: シェルスクリプトが見つからない")
        return 0
    offenders = []
    for path in files:
        for number, line in enumerate(open(path, errors="replace").read().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in UNBRACED_BEFORE_MULTIBYTE.finditer(line):
                offenders.append(f"{path}:{number}: {m.group(0)}（直後 '{line[m.end()]}'）")
    if offenders:
        print("bash 3.2 が多バイト文字を変数名に食い込ませる。${VAR} で囲うこと:")
        print("\n".join(f"  {o}" for o in offenders))
        return 1
    print(f"✅ シェルスクリプト {len(files)} 本")
    return 0


if __name__ == "__main__":
    sys.exit(main())
