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
`RULES` に (パターン, 理由, 許す場所, **当たるべき見本**) を 1 行足す。許す場所は
「そこだけは正しい」経路（記録・テスト・説明）に限る。
⚠️ **通すために許可を足したくなったら、それは規則の見直し時**。

## ⚠️⚠️ 見本（4 つめ）が要る理由（2026-10-03 に踏んだ・ADR-253）
`?? scanProgressRemaining` を禁じる規則を足し、**手で grep して当たることを確かめた**のに、
スクリプトからは**一度も当たらなかった**。原因は正規表現の方言——
`[\\w.]` はここで走る POSIX の `/usr/bin/grep -E` では「`\\`・`w`・`.` の 3 文字」になる
（対話シェルの `grep` は別物で `\\w` を解す）。コメント行だけに当たっていたので
「✅ 残っていません」と出続けた。**検査を足したのに検査されていない**＝ADR-251 の形そのもの。

そこで各規則に「**これには必ず当たらなければならない**」見本を持たせ、
走るたびに**同じ grep で**確かめる。規則が死んでいたら、その場で落ちる。
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (正規表現, なぜ禁じたか, 許す経路の部分一致, 当たるべき見本＝規則が生きている証拠)
RULES: list[tuple[str, str, tuple[str, ...], str]] = [
    (r"\.fetchOffset\s*=",
     "オフセットのページングは O(n²) で、走査中の挿入で行が飛ぶ（ADR-143/239）。"
     "キーセット・ページング（前回の最後より大きいもの）にする。",
     (),
     "descriptor.fetchOffset = cursor"),
    (r"\bObservableObject\b",
     "状態は Swift Observation（@Observable）で持つ（CLAUDE.md）。"
     "iOS 26 SDK では Combine の明示 import が要るため使わない。",
     (),
     "final class Store: ObservableObject {"),
    (r"^\s*import Combine\b",
     "Combine は使わない（CLAUDE.md・@Observable に統一）。",
     (),
     "import Combine"),
    (r"isStoredInMemoryOnly:\s*true",
     "テスト用のインメモリ容器は `MosaicSupport.makeInMemoryModelContainer(for:)` だけが作る。"
     "名前を毎回変える／生成を直列にする の 2 つが要り、"
     "錠が無いと CoreData の `_generateTriggerSQL` で SIGSEGV して"
     "**テストの実行体だけが消える**（ハングに見える・2026-09-30 に観測）。"
     "6 つのストアにコピーされて錠を持つのは 2 つだけ、という状態だった。",
     ("MosaicSupport/ResilientModelContainer.swift",),
     "ModelConfiguration(isStoredInMemoryOnly: true)"),
    # ⚠️ `[\w.]` と書かない（`[A-Za-z0-9_.]` と書く）。ここが走るのは POSIX の
    #    `/usr/bin/grep -E` で、ブラケットの中の `\w` は**「`\`・`w`・`.` の 3 文字」**に
    #    なってしまう。対話シェルの `grep` は別物（ugrep）で `\w` を解すので、
    #    **手で試すと当たるのにスクリプトでは当たらない**——この規則で実際に踏んだ（ADR-253）。
    (r"\?\?\s*[A-Za-z0-9_.]*\bscanProgressRemaining\b",
     "「分からない」を `scanProgressRemaining` で埋めない（ADR-207/252/253）。"
     "あれはスキャン中しか書かれない＝それ以外は 0 なので、`?? scanProgressRemaining` は"
     "**「分からない」を静かに「終わった」に丸める**。顔の残作業を見る側は "
     "`lastKnownFaceBacklog`（前の起動の記録まで見て、本当に分からないときだけ nil）を使う。"
     "⚠️ ADR-252 は `gatherInputs` でこの式を直したが、隣の `logStalledPasses` を直し漏れ、"
     "**顔の停滞検出が一度も効かない**まま残っていた（ADR-253）。"
     "進捗の表示に使うのは正しい（その場合は `isScanning` で囲う）。",
     (),
     # ⚠️ 見本は**実際に踏んだ式そのもの**（`stores.peopleEngine.` を跨ぐ形）。
     #    ここを `?? scanProgressRemaining` だけにすると、方言の取りこぼしを見逃す。
     "pending: stores.peopleEngine.faceBacklog ?? stores.peopleEngine.scanProgressRemaining,"),
    # ⚠️ **`faceBacklog ??` を丸ごと禁じない**（最初はそう書いて、正しい 2 か所に当たった）。
    #    禁じたいのは「**分からない → 終わった**」の向きだけ。`?? 1`（＝あるかもしれない側へ
    #    倒す・ADR-252）と `?? (UserDefaults…)`（＝`lastKnownFaceBacklog` 本体）は正しい。
    #    規則を通すために許可を足したくなったら、それは規則の見直し時（この冒頭の方針）。
    (r"faceBacklog\s*\?\?\s*0([^0-9]|$)",
     "`faceBacklog` の nil（＝この起動でまだ測っていない）を **0 で潰さない**"
     "（ADR-207/252/253）。読む側は `lastKnownFaceBacklog`（前の起動の記録まで見る）を使い、"
     "判断する側は `Int?` で受けて nil を「あるかもしれない」側へ倒す。"
     "⚠️ 潰した結果は毎回**同じ向きの嘘**になる——夜間の窓では「生成を見送らない」、"
     "停滞検出では「顔は健全」、ブーストの終わりでは「すべて解析済みです」。"
     "顔モデルが無い端末だけは呼び出し側が 0 を渡してよい（起こり得ない処理）。",
     (),
     "faceBacklog: people.faceBacklog ?? 0)); return"),
    (r"mediaSubtypes\s*&\s*%d",
     "顔スキャンの候補の条件は `faceScanCandidateFetchOptions(newestFirst:)` **だけ**が持つ"
     "（ADR-252 の宿題）。以前は同じ NSPredicate を「候補を数える側」と「列挙する側」の"
     "2 か所に書き写していた——ずれると「変わっていないのに指紋が動く」か"
     "「変わったのに動かない」のどちらかになり、どちらもゲートが静かに壊れる（ADR-250/251）。",
     ("PhotosFeatureKit/AnalysisCandidates.swift",),
     'NSPredicate(format: "mediaSubtypes & %d != 0", subtype)'),
]

SEARCH = [ROOT / "MosaicPhotos"] + sorted((ROOT / "Packages").glob("*/Sources"))


def grep(pattern: str, targets: list[str]) -> list[str]:
    """走査に使う唯一の口。⚠️ **見本の確認もここを通す**——別の正規表現エンジン
    （Python の `re`・対話シェルの grep）で確かめると、方言の違いを見逃す（ADR-253）。"""
    return subprocess.run(["grep", "-rnE", "--include=*.swift", pattern, *targets],
                          capture_output=True, text=True).stdout.splitlines()


def check_rules_can_fire(tmp: Path) -> list[str]:
    """各規則が**自分の見本には当たる**こと（＝規則が生きていること）。

    ⚠️ これが無いと、方言の取りこぼしで**一度も当たらない規則**が
    「✅ 残っていません」の顔で居座る（ADR-253 で実際にそうなった）。
    """
    out: list[str] = []
    for pattern, _why, _allowed, sample in RULES:
        probe = tmp / "Probe.swift"
        probe.write_text(sample + "\n", encoding="utf-8")
        if not grep(pattern, [str(probe)]):
            out.append(f"/{pattern}/ は見本に当たらない（規則が死んでいる）: {sample}")
    return out


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
    # ⚠️ **規則が生きているかを先に確かめる**（ADR-253）。死んだ規則は「違反ゼロ」と
    #    見分けがつかないので、走査より前に落とす。
    with tempfile.TemporaryDirectory() as tmp:
        dead = check_rules_can_fire(Path(tmp))
    if dead:
        failed = True
        print("❌ 当たらない規則があります（検査が静かに空振りしています）:")
        for line in dead:
            print(f"   {line}")
        print("   ⚠️ ここで走る grep は POSIX の `/usr/bin/grep -E` で、"
              "ブラケットの中の `\\w` は使えません（`[A-Za-z0-9_.]` と書く）。")
        print()
    for pattern, why, allowed, _sample in RULES:
        hits = grep(pattern, [str(p) for p in SEARCH])
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
    print(f"✅ 使わないと決めた書き方 {len(RULES)} 件（いずれも見本に当たることを確認済み）＋キーセットの並び＋台帳の匿名化は、どこにも残っていません。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
