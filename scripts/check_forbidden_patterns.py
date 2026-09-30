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
    (r"isStoredInMemoryOnly:\s*true",
     "テスト用のインメモリ容器は `MosaicSupport.makeInMemoryModelContainer(for:)` だけが作る。"
     "名前を毎回変える／生成を直列にする の 2 つが要り、"
     "錠が無いと CoreData の `_generateTriggerSQL` で SIGSEGV して"
     "**テストの実行体だけが消える**（ハングに見える・2026-09-30 に観測）。"
     "6 つのストアにコピーされて錠を持つのは 2 つだけ、という状態だった。",
     ("MosaicSupport/ResilientModelContainer.swift",)),
]

SEARCH = [ROOT / "MosaicPhotos"] + sorted((ROOT / "Packages").glob("*/Sources"))


# ⚠️ 行ごとの正規表現では見えない規則は、関数で見る。
def check_keyset_sort_comparator() -> list[str]:
    """キーセット・ページングの並びは `.lexical` でなければならない（ADR-178/143/239）。

    続きの判定を `$0.X > cursor` で書くなら、並べ替えも `>` と**同じ順序**でないと
    継ぎ目で行が飛ぶ／同じ行を 2 度読む。`AutoAlbumStore` / `TagStore` /
    `DropboxCacheStore` / `FaceStore+Explain` は `.lexical` を明示しているのに、
    `FaceStore.forEachFacePage` だけ抜けていた（2026-09-29 のレビューで発見）。

    見方: **キーセットの述語を持つファイル**では、その列の `SortDescriptor` に
    必ず `comparator: .lexical` が付いていること。
    """
    keyset = re.compile(r"#Predicate\s*\{\s*\$0\.(\w+)\s*>\s*\w+")
    out: list[str] = []
    for base in SEARCH:
        for path in base.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            keys = set(keyset.findall(text))
            if not keys:
                continue
            for lineno, line in enumerate(text.splitlines(), 1):
                body = line.lstrip()
                if body.startswith("//"):
                    continue
                for key in keys:
                    if re.search(r"SortDescriptor\(\\\." + key + r"\b", line) \
                            and "comparator: .lexical" not in line:
                        out.append(f"{path}:{lineno}:{body}")
    return out


# ⚠️ 台帳を書き出すときの匿名化は、モデルごとに手で書いてある。足したのに書き忘れると
#    **実フォルダ名・人物名が入った台帳を共有してしまう**（ADR-243 で実際に一度そうなった）。
#
# ⚠️ 見るのは「モデルが全部載っているか」**ではない**。`FaceCorrection` は id が UUID で
#    埋め込みと数値しか持たないので、載せる必要が無い（最初はそう書いて誤検知した）。
#    本当の規則は「**人を指す文字列を持つモデルは匿名化されていること**」。
LEDGER_IDENTIFYING_FIELDS = ("refKey", "faceID", "coverFaceID", "name")


def check_ledger_redaction_covers_identifying_models() -> list[str]:
    """人を指す文字列を持つ台帳モデルが `FaceLedgerBackup.swift` で匿名化されていること。

    ⚠️ 顔の特徴量（埋め込み）は**外さない**（書き出し先はローカル限定・記録に明記）。
    ここが見るのは、写真のパスと人が付けた名前だけ。
    """
    root = ROOT / "Packages/FaceCore/Sources/FaceCore/Faces"
    store, backup = root / "FaceStore.swift", root / "FaceLedgerBackup.swift"
    if not store.exists() or not backup.exists():
        return []
    m = re.search(r"ledgerSchema\s*=\s*Schema\(\[(.*?)\]\)", store.read_text(encoding="utf-8"), re.S)
    if not m:
        return ["FaceStore.swift: ledgerSchema が読めない（検査が空振りしている）"]
    names = re.findall(r"(\w+)\.self", m.group(1))
    # ⚠️ `@Model` は 1 つのファイルに集まっていない（`PeopleGroupRecord` は PeopleGroups.swift）。
    #    宣言はディレクトリ全体から探す——1 ファイルだけ見て「見つからない」と言うと空振りする。
    text = "\n".join(f.read_text(encoding="utf-8") for f in sorted(root.glob("*.swift")))
    redaction = backup.read_text(encoding="utf-8")
    out: list[str] = []
    for name in names:
        body = re.search(r"final class " + name + r"\b(.*?)\n}", text, re.S)
        if not body:
            out.append(f"{name} の宣言が見つからない（検査が空振りしている）")
            continue
        fields = [f for f in LEDGER_IDENTIFYING_FIELDS
                  if re.search(r"var " + f + r"\s*:", body.group(1))]
        if fields and f"FetchDescriptor<{name}>" not in redaction:
            out.append(f"FaceLedgerBackup.swift に {name} の匿名化が無い"
                       f"（{'/'.join(fields)} がそのまま書き出される）")
    return out


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
    uncovered = check_ledger_redaction_covers_identifying_models()
    if uncovered:
        failed = True
        print("❌ 台帳の匿名化に漏れがあります:")
        for line in uncovered:
            print(f"   {line}")
        print()
    strays = check_keyset_sort_comparator()
    if strays:
        failed = True
        print("❌ キーセット・ページングの並びに `comparator: .lexical` が付いていません:")
        print("   理由: 続きの判定が `$0.X > cursor` なので、並べ替えが `>` と違う順序だと")
        print("         継ぎ目で行が飛ぶ／同じ行を 2 度読む（ADR-178/143/239）。")
        for line in strays[:10]:
            print(f"   {line}")
        print()
    if failed:
        print("⚠️ 「同じ規則が複数の場所に散っていて片方だけ直す」は、")
        print("   実機で繰り返し出ている不具合の最多の形です（2026-09-28 に数えた）。")
        return 1
    print(f"✅ 使わないと決めた書き方 {len(RULES)} 件＋キーセットの並び＋台帳の匿名化は、どこにも残っていません。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
