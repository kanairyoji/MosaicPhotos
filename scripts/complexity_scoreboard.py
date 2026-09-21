#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""複雑さ・保守負担のスコアボード（docs/architecture-note/records/complexity-scoreboard.md の計測側）。

    python3 scripts/complexity_scoreboard.py            # 表を出す
    python3 scripts/complexity_scoreboard.py --json     # 機械可読

## なぜスクリプトにするか
「どこが複雑か」を体感や印象で決めると、直したばかりの場所が目につき、静かに腐っている場所が
見落とされる。判断の材料は**同じ手順で測り直せる**ようにしておく（search-quality.md /
face-accuracy.md と同じ「台帳」の考え方）。

## 指標が答えられないこと
- **churn は遅行指標**。直したばかりの領域は「過去の負担」が高いまま出る。だから履歴系と
  構造系のスコアを**分けて**出す。次に何をするかは構造系で見る。
- **負担が外部化される部品を、ファイル単位の churn は取りこぼす**（実例: 背景ゲート網は
  自分のファイルが 550 行・fix 6 件しかないのに、述語の使い方を直した fix が 19 件あった）。
  それを拾うのが `外部fix`＝その型の呼び出しを書き換えた fix コミット数。
- 「対策でどれだけ良くなるか」は**測れない**。台帳（.md）側に判断として書く。
"""
import argparse, json, os, re, subprocess, sys

# 領域の定義。paths＝行数・状態・分岐などファイル単位の指標の対象、
# types＝結合と「外部fix」を数えるための型名、pure＝その領域の純ロジック（テストの受け皿）。
AREAS = [
    ("1", "顔クラスタ後処理",
     ["Packages/FaceCore/Sources/FaceCore/Faces/FaceStore"],
     ["FaceStore"], ["FaceClustering", "FaceQualityGate", "FaceTuning", "FacePersonGrouping",
                     "FaceClusteringSetup", "FaceNameFollowing", "FaceSeedBuilder"]),
    ("2", "PeopleEngine",
     ["Packages/FaceCore/Sources/FaceCore/Faces/PeopleEngine"],
     ["PeopleEngine"], ["FaceScanControl", "SingleFlightTask", "DebouncedTask"]),
    ("3", "家族共有",
     ["Packages/BackupKit/Sources/BackupKit/Share/"],
     ["ShareSyncEngine", "DropboxShareCopier", "ShareAnalysisData"],
     ["SharePlanning", "ShareNaming", "ShareImportPlanning"]),
    ("4", "背景ゲート網",
     ["Packages/MosaicSupport/Sources/MosaicSupport/BackgroundYield",
      "Packages/MosaicSupport/Sources/MosaicSupport/BackgroundActivityMonitor",
      "Packages/MosaicSupport/Sources/MosaicSupport/HeavyWorkTiming"],
     ["BackgroundYield", "BackgroundActivityMonitor"],
     ["HeavyWorkTiming", "ThermalPolicy", "SingleFlightTask", "DebouncedTask"]),
    ("5", "夜間窓スケジューラ",
     ["MosaicPhotos/HeavyWorkScheduler", "MosaicPhotos/NightlyWorkPolicy"],
     ["HeavyWorkScheduler"], ["NightlyWorkPolicy", "NightlyPlan"]),
    ("6", "解析トリクル起動",
     ["Packages/AutoAlbumCore/Sources/AutoAlbumCore/AIAlbum/AutoAlbumEngine+Recognition",
      "Packages/AutoAlbumCore/Sources/AutoAlbumCore/AutoAlbumEngine.swift"],
     ["AutoAlbumEngine"], ["BackgroundProcessing", "AnalysisOrder", "TricklePlan"]),
    ("7", "AI増分再評価",
     ["Packages/AutoAlbumCore/Sources/AutoAlbumCore/AIAlbum/AIAlbumService"],
     ["AIAlbumService"], ["AIAlbumSearcher", "HybridFusion", "QueryEvaluator"]),
    ("8", "バックアップ",
     ["Packages/BackupKit/Sources/BackupKit/BackupRunner",
      "Packages/BackupKit/Sources/BackupKit/BackupEngine",
      "Packages/BackupKit/Sources/BackupKit/BackgroundUpload/"],
     ["BackupRunner", "BackupEngine", "BackgroundUploadSession"],
     ["BackupMetadataPlanning", "OffloadPlanning"]),
    ("9", "DropboxPhotoStore",
     ["Packages/DropboxCore/Sources/DropboxCore/Store/DropboxPhotoStore"],
     ["DropboxPhotoStore"], ["DropboxCacheNaming"]),
    ("10", "解析状況/ブースト",
     ["MosaicPhotos/Settings/AIAnalysisStatusView", "MosaicPhotos/Settings/AnalysisStatusModel",
      "MosaicPhotos/AnalysisSession", "MosaicPhotos/AnalysisDriver", "MosaicPhotos/AnalysisWindowHealth"],
     ["AIAnalysisStatusView", "AnalysisSession", "AnalysisDriver", "AnalysisStatusModel"],
     ["AnalysisSessionPolicy", "AnalysisDriverPolicy", "AnalysisWindowHealth"]),
]

# 「直したものが壊れた」を示す語。コミットの題名と本文から拾う。
REGRESSION = re.compile(r"退行|再発|戻って|戻った|レビュー指摘|直したはず|同じ穴|作った事故|"
                        r"作った退行|見落と|撤回|誤りだった")
# 継ぎ足しの跡（後から足した規則の密度）。
PATCH_MARK = re.compile(r"⚠️|レビュー指摘|追記|追補|diagnostics-\d+|実障害|実フィードバック")
FUNC_HEAD = re.compile(r"\s*(?:@\w+\s+)*(?:public |private |internal |fileprivate |static |override |"
                       r"nonisolated |mutating |final |@discardableResult )*func\s+\w+")
VAR_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |private |internal |fileprivate |static )*"
                      r"var\s+\w+")


# 本体を持つ宣言の頭（`func` / `init` / `subscript`）。折り返したシグネチャの 1 行目を捕まえる。
DECL_HEAD = re.compile(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |private |internal |fileprivate |static |"
                       r"override |nonisolated |mutating |final |convenience |required |@discardableResult )*"
                       r"(?:func\s+\w+|init\b|subscript\b)")

def stored_state(text):
    """**型が持ち越す可変状態**の数（＝不整合になり得る組み合わせ）。

    ⚠️ 以前は行頭の `var` を無差別に数えていたので、次の 3 つが混ざっていた。
    重み 13（構造系で最大）なので、順位そのものが歪んでいた。

    - **関数・クロージャ・計算プロパティの中のローカル `var`**: 手続きの中で閉じている。
      長い関数の指標としては意味があるが、それは `maxBranches` が見ている。
    - **計算プロパティ**（`var x: T { ... }`）: 由来が 1 つに決まる派生値で、
      **状態ではない**。むしろ状態を減らす書き方なので、加点すると逆向きの誘導になる。
    - Codable の DTO フィールドは数えたままにする（型が持ち越す値ではある）。

    ⚠️ **本体に入ったかの判定は、`{` が宣言と同じ行に来ない場合がある**。
    Swift では引数が多いと `func f(a: Int,` / `        b: Int) -> T {` と折り返すのが普通で、
    宣言行だけを見ていると本体に入ったと分からない。分からないと中のローカル変数を
    全部「状態」に数える——最初の修正がこれを踏み、顔クラスタ後処理を
    **63**（正しくは 13）と報告していた。折り返しは `pending` で跨ぐ。
    """
    stored = 0
    depth = 0
    body = None        # 本体に入った深さ（そこへ戻ったら型スコープに復帰）
    pending = False    # 宣言は見たが本体の `{` がまだ来ていない（折り返したシグネチャ）
    for raw in text.split("\n"):
        line = raw.split("//")[0]
        if body is None and not pending and VAR_DECL.match(line):
            brace, eq = line.find("{"), line.find("=")
            computed = brace >= 0 and (eq < 0 or eq > brace) \
                and "didSet" not in line and "willSet" not in line
            if computed:
                body = depth       # 計算プロパティの本体も型スコープではない
            else:
                stored += 1
                if brace >= 0:
                    body = depth   # `var x = { … }()` のような初期化クロージャ
        elif body is None and DECL_HEAD.match(line):
            pending = True
        # ⚠️ **開き括弧が閉じ括弧より多い行**でだけ本体に入ったとみなす。既定引数の
        # クロージャ（`onProgress: (Int) -> Void = { _ in },`）は括弧が釣り合うので、
        # ここで誤って本体に入ったことにしない。
        if pending and line.count("{") > line.count("}"):
            body = depth
            pending = False
        depth += line.count("{") - line.count("}")
        if body is not None and depth <= body:
            body = None
    return stored
BRANCH = re.compile(r"\b(if|guard|switch|case|while|for|catch)\b|&&|\|\||\?\?")

# 履歴系（これまでの欠陥・退行）と構造系（いまのコードのリスク）で重みを分ける。
HISTORY_WEIGHTS = [("regressionRate", 20), ("fixPerKLOC", 15), ("externalFixPerKLOC", 15), ("fixRecent", 15)]
STRUCTURE_WEIGHTS = [("mutableState", 13), ("marksPerKLOC", 8), ("coupling", 7), ("maxBranches", 7)]
TEST_WEIGHT = 5          # テストが薄いほど加点
DIFF_LOG_DEPTH = 400     # 「外部fix」を数える範囲（コミット数）
RECENT_DEPTH = 100       # 「直近の勢い」の範囲


def sh(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def load_commits():
    raw = sh(["git", "log", "--format=@@@%H%x09%s%x09%b", "--name-only"])
    commits, cur = [], None
    for line in raw.split("\n"):
        if line.startswith("@@@"):
            parts = line[3:].split("\t")
            cur = {"h": parts[0], "subj": parts[1] if len(parts) > 1 else "",
                   "body": parts[2] if len(parts) > 2 else "", "files": []}
            commits.append(cur)
        elif line.strip() and cur is not None:
            cur["files"].append(line.strip())
    commits.reverse()
    return commits


def load_diffs():
    """直近 DIFF_LOG_DEPTH コミットの (題名, 変更行) を返す。"""
    out = sh(["git", "log", "--format=@@@%H%x09%s", "-p", "--unified=0", f"-{DIFF_LOG_DEPTH}"])
    diffs, cur, buf = [], None, []
    for line in out.split("\n"):
        if line.startswith("@@@"):
            if cur:
                diffs.append((cur, buf))
            cur, buf = line[3:].split("\t", 1)[1], []
        elif cur and line[:1] in "+-" and not line.startswith(("+++", "---")):
            buf.append(line)
    if cur:
        diffs.append((cur, buf))
    return diffs


def load_sources():
    src, tests = {}, {}
    for d, _, files in os.walk("."):
        if "/.build" in d or d.startswith("./.git"):
            continue
        for f in files:
            if not f.endswith(".swift"):
                continue
            p = os.path.join(d, f)[2:]
            text = open(p, encoding="utf-8", errors="ignore").read()
            (tests if "/Tests/" in p or p.startswith("MosaicPhotosTests") else src)[p] = text
    return src, tests


def max_branches(text):
    """30 行以上の関数のうち、最も分岐が多いものの分岐数。"""
    lines, best, i = text.split("\n"), 0, 0
    while i < len(lines):
        if FUNC_HEAD.match(lines[i]):
            depth, started, j = 0, False, i
            while j < len(lines):
                s = re.sub(r"//.*", "", re.sub(r'"(?:[^"\\]|\\.)*"', "", lines[j]))
                depth += s.count("{") - s.count("}")
                if s.count("{"):
                    started = True
                if started and depth <= 0:
                    break
                j += 1
            body = lines[i:j + 1]
            if len(body) >= 30:
                best = max(best, sum(len(BRANCH.findall(re.sub(r"//.*", "", x))) for x in body))
            i = j + 1 if j > i else i + 1
        else:
            i += 1
    return best


def measure():
    commits, diffs, (src, tests) = load_commits(), load_diffs(), load_sources()
    recent = {c["h"] for c in commits[-RECENT_DEPTH:]}
    rows = []
    for aid, name, paths, types, pure in AREAS:
        own = [p for p in src if any(p.startswith(x) for x in paths) and "/Tests/" not in p]
        loc = sum(len(src[p].split("\n")) for p in own) or 1

        fix = fix_recent = regressions = 0
        for c in commits:
            if not any(any(f.startswith(p) for p in paths) for f in c["files"]):
                continue
            if c["subj"].startswith("fix"):
                fix += 1
                if c["h"] in recent:
                    fix_recent += 1
            if REGRESSION.search(c["subj"] + c["body"]):
                regressions += 1

        # 外部化された負担: その型の呼び出しを書き換えた fix コミット数。
        call_pat = re.compile("|".join(re.escape(t) + r"\." for t in types))
        external_fix = sum(1 for subj, lines in diffs
                           if subj.startswith("fix") and any(call_pat.search(l) for l in lines))

        coupling = len({p for p, t in src.items()
                        if any(re.search(r"\b" + re.escape(x) + r"\b", t) for x in types)
                        and not any(p.startswith(y) for y in paths)})
        state = sum(stored_state(src[p]) for p in own)
        marks = sum(len(PATCH_MARK.findall(src[p])) for p in own)
        branches = max((max_branches(src[p]) for p in own), default=0)
        test_count = sum(len(re.findall(r"@Test|func test", t)) for p, t in tests.items()
                         if any(re.search(r"\b" + re.escape(x) + r"\b", t) for x in types + pure))

        rows.append(dict(
            id=aid, name=name, loc=loc, files=len(own),
            fix=fix, fixRecent=fix_recent, regressions=regressions, externalFix=external_fix,
            mutableState=state, marks=marks, maxBranches=branches, coupling=coupling, tests=test_count,
            fixPerKLOC=fix * 1000 / loc, externalFixPerKLOC=external_fix * 1000 / loc,
            marksPerKLOC=marks * 1000 / loc, testsPerKLOC=test_count * 1000 / loc,
            regressionRate=regressions / max(fix, 1)))
    return rows


def score(rows):
    def rng(key):
        vals = [r[key] for r in rows]
        return min(vals), max(vals)

    def norm(v, lo, hi):
        return max(0.0, min(1.0, (v - lo) / (hi - lo))) if hi > lo else 0.0

    for r in rows:
        r["history"] = round(sum(norm(r[k], *rng(k)) * w for k, w in HISTORY_WEIGHTS))
        structure = sum(norm(r[k], *rng(k)) * w for k, w in STRUCTURE_WEIGHTS)
        structure += (1 - norm(r["testsPerKLOC"], *rng("testsPerKLOC"))) * TEST_WEIGHT
        r["structure"] = round(structure)
        r["burden"] = r["history"] + r["structure"]
    return rows



# ⚠️ **計測の道具にもテストが要る**（2026-09-21・1 日で 2 回バグを入れた）。
# `python3 scripts/complexity_scoreboard.py --selftest` で通す。
# 指標を変えたら、まずここへ「壊れていたときの入力」を 1 件足すこと。
SELFTEST_CASES = [
    ("素の格納プロパティ", 2, """
struct A {
    var a = 0
    private var b: String?
}
"""),
    ("計算プロパティは状態ではない", 1, """
struct A {
    var stored = 0
    var derived: Int { stored * 2 }
    var multiline: Bool {
        stored > 0
    }
}
"""),
    ("計算プロパティの本体のローカルは数えない", 1, """
struct A {
    var stored = 0
    var summary: String {
        var out = ""
        for _ in 0..<3 { out += "x" }
        return out
    }
}
"""),
    ("関数の中のローカルは数えない", 1, """
struct A {
    var stored = 0
    func run() {
        var local = 0
        local += 1
    }
}
"""),
    # ⚠️ 実際に踏んだ穴。折り返したシグネチャは本体の `{` が別の行に来る。
    ("折り返したシグネチャの本体も、中は数えない", 1, """
struct A {
    var stored = 0
    func run(first: Int,
             second: Int) -> Int {
        var local = first
        local += second
        return local
    }
}
"""),
    # ⚠️ 既定引数のクロージャは括弧が釣り合う。ここで本体に入ったことにすると、
    # そのあとの本体を型スコープと誤認して中のローカルを全部数える。
    ("既定引数のクロージャで本体に入ったと誤解しない", 1, """
struct A {
    var stored = 0
    func run(onEach: (Int) -> Void = { _ in },
             limit: Int = 10) {
        var local = 0
        local += limit
    }
}
"""),
    ("didSet 付きは格納プロパティ", 1, """
struct A {
    var watched: Int = 0 {
        didSet { print(watched) }
    }
}
"""),
    ("クロージャで初期化する格納プロパティは 1 件（中身は数えない）", 1, """
struct A {
    var made: Int = {
        var seed = 1
        return seed + 1
    }()
}
"""),
    ("init の中のローカルは数えない", 1, """
struct A {
    var stored: Int
    init(value: Int,
         extra: Int) {
        var local = value
        local += extra
        stored = local
    }
}
"""),
]


def selftest():
    bad = 0
    for name, expected, text in SELFTEST_CASES:
        got = stored_state(text)
        mark = "✔" if got == expected else "✘"
        if got != expected:
            bad += 1
        print(f"{mark} {name}: 期待 {expected} / 実測 {got}")
    print("すべて通過" if bad == 0 else f"{bad} 件が食い違っている")
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true", help="指標の数え方だけを確かめる（リポジトリを読まない）")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    rows = score(measure())
    if args.json:
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=2)
        return
    print("【保守負担】 合計 = 履歴（これまでの欠陥・退行）＋ 構造（いまのコードのリスク）")
    print("※ churn は遅行指標。直したばかりの領域は履歴だけ高く出る——"
          "**次に何をするかは「構造」で見る**。")
    head = (f"{'順':>2}{'ID':>3} {'領域':<20}{'合計':>5}{'履歴':>5}{'構造':>5} | "
            f"{'行数':>6}{'fix/kL':>7}{'外部/kL':>8}{'退行率':>7}{'状態':>5}{'分岐':>5}{'結合':>5}{'ﾃｽﾄ/kL':>7}")
    print(head)
    for i, r in enumerate(sorted(rows, key=lambda x: -x["burden"]), 1):
        print(f"{i:>2}{r['id']:>3} {r['name']:<20}{r['burden']:5d}{r['history']:5d}{r['structure']:5d} | "
              f"{r['loc']:6d}{r['fixPerKLOC']:7.1f}{r['externalFixPerKLOC']:8.1f}{r['regressionRate']:7.2f}"
              f"{r['mutableState']:5d}{r['maxBranches']:5d}{r['coupling']:5d}{r['testsPerKLOC']:7.1f}")
    print()
    print("【構造リスク順（次にどこを直すか）】")
    for i, r in enumerate(sorted(rows, key=lambda x: -x["structure"]), 1):
        print(f"{i:>2}{r['id']:>3} {r['name']:<20}構造={r['structure']:3d}  "
              f"状態={r['mutableState']:3d} 分岐={r['maxBranches']:3d} 結合={r['coupling']:3d} "
              f"ﾃｽﾄ/kL={r['testsPerKLOC']:5.1f}")


if __name__ == "__main__":
    main()
