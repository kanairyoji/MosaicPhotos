#!/usr/bin/env python3
"""連写・服装の連結（ADR-211/212）を計測するための PIPA サブセットを集める。

PIPA（People In Photo Albums・Zhang et al. CVPR'15）は Flickr の個人アルバムに
頭の矩形と人物 ID を付けたデータセット。撮影時刻（Oh et al. ICCV'15 の date_vec）も
配布されており、**同じアルバムで 3 秒以内に続く写真＝本物の連写**が 4,000 組ある。
顔のデータセット（FG-NET / LFW）には連写も服装も無いので、ここでしか測れない。

画像の一括配布は終わっているため、写真 ID から Flickr の公開ページを開いて
大きい版の URL を読む（API キー不要）。約 3 割は削除済みで取れない。

⚠️ **長辺 2048px 版を取る**。PIPA は集合写真が多く、1024px では顔が 50〜70px しかない。
本番の品質ゲート（80px 未満は捨てる・ADR-90）を素通りできず、1024px 版 150 枚で顔が
6 個しか残らなかった。ゲートは変えずに「顔が大きめに写っている写真」として測る。
PIPA の座標は 1024px 版の画素なので、取得した版との比で換算する。

出力（既定 ~/DEV/tmp/face-eval-pipa/）:
  images/<photo_id>.jpg
  annotations.csv  — photo,album,date,x,y,w,h,identity（x,y,w,h は**取得した画像の画素**・原点左上）

⚠️ 画像は写真ごとに異なる CC ライセンス。手元の計測にのみ使い、リポジトリへ入れない。

使い方: python3 scripts/fetch_pipa_eval.py [--photos 3000]
"""
import argparse, csv, io, json, os, re, subprocess, sys, time, urllib.request, tarfile
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

META_URL = "https://raw.githubusercontent.com/coallaoh/PIPA_dataset/master/all_data.txt"
DATE_URL = "http://datasets.d2.mpi-inf.mpg.de/oh15iccv/data_timestamp.mat"
UA = {"User-Agent": "Mozilla/5.0 (research dataset fetch)"}


def get(url, timeout=30, attempts=4):
    """⚠️ curl で取る。urllib は一括取得の途中で応答が返らないまま固まり、
    全ワーカーが止まった（タイムアウトも効かなかった）。curl は接続・全体の上限を自分で持つ。
    一括取得では Flickr のレート制限にも当たるので、待ちを伸ばしながら取り直す。"""
    for attempt in range(attempts):
        r = subprocess.run(["curl", "-sfL", "--connect-timeout", "10", "--max-time", str(timeout),
                            "-A", UA["User-Agent"], url], capture_output=True)
        if r.returncode == 0 and r.stdout:
            return r.stdout
        if attempt == attempts - 1:
            raise RuntimeError(f"curl rc={r.returncode}")
        time.sleep(2 ** attempt * 3)


def load_dates(path):
    """date_vec（63188×6 uint16）を読む。scipy が無ければ venv を勧める。"""
    try:
        import scipy.io as sio
    except ImportError:
        sys.exit("scipy が要る: python3 -m venv v && v/bin/pip install scipy && v/bin/python " + sys.argv[0])
    return sio.loadmat(path)["date_vec"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.expanduser("~/DEV/tmp/face-eval-pipa"))
    ap.add_argument("--photos", type=int, default=3000)
    ap.add_argument("--max-side", type=int, default=2048)
    args = ap.parse_args()
    os.makedirs(os.path.join(args.out, "images"), exist_ok=True)

    meta_path = os.path.join(args.out, "all_data.txt")
    date_path = os.path.join(args.out, "data_timestamp.mat")
    if not os.path.exists(meta_path):
        open(meta_path, "wb").write(get(META_URL))
    if not os.path.exists(date_path):
        open(date_path, "wb").write(get(DATE_URL, timeout=120))
    rows = [l.split() for l in open(meta_path)]
    dates = load_dates(date_path)

    # 写真ごとに頭・人物・時刻をまとめる（時刻の無い写真は連写を測れないので除く）。
    photos = {}
    for r, d in zip(rows, dates):
        if d[0] == 0:
            continue
        album, pid = r[0], r[1]
        x, y, w, h, ident = map(int, r[2:7])
        p = photos.setdefault(pid, {"album": album, "date": datetime(*map(int, d)), "heads": []})
        p["heads"].append((x, y, w, h, ident))

    # アルバムを「連写の組の多さ」で並べ、写真数の上限までアルバム単位で取る
    # （アルバムを途中で切ると場面が欠けて、服装の比較が実態より不利になる）。
    by_album = defaultdict(list)
    for pid, p in photos.items():
        by_album[p["album"]].append((p["date"], pid))
    score = {}
    for album, lst in by_album.items():
        lst.sort()
        score[album] = sum(1 for a, b in zip(lst, lst[1:]) if 0 <= (b[0] - a[0]).total_seconds() <= 3)
    chosen = []
    for album in sorted(by_album, key=lambda a: (-score[a], a)):
        if len(chosen) >= args.photos:
            break
        chosen.extend(pid for _, pid in by_album[album])
    print(f"アルバム選択: 写真 {len(chosen)} 枚（連写の組 {sum(score[a] for a in {photos[p]['album'] for p in chosen})}）")

    scales = {}
    scale_path = os.path.join(args.out, "scales.json")
    if os.path.exists(scale_path):
        scales = json.load(open(scale_path))

    def fetch(pid):
        dst = os.path.join(args.out, "images", f"{pid}.jpg")
        if os.path.exists(dst) and pid in scales:
            return pid, "cached"
        try:
            html = get(f"https://www.flickr.com/photo.gne?id={pid}").decode("utf-8", "replace")
        except Exception as e:
            return pid, f"page:{e}"
        # サイズ一覧から長辺 max_side 以下で最大のもの。PIPA の座標は「長辺 1024 以下で最大の版」の
        # 画素なので、その長辺も控えて換算比を出す。
        best = None
        ref = None
        for m in re.finditer(r'"(\w+)":\{"displayUrl":"([^"]+)","width":(\d+),"height":(\d+)', html):
            url, w, h = m.group(2), int(m.group(3)), int(m.group(4))
            side = max(w, h)
            if side <= args.max_side and (best is None or side > best[1]):
                best = (url, side)
            if side <= 1024 and (ref is None or side > ref):
                ref = side
        if best is None or ref is None:
            return pid, "gone"
        url = best[0].replace("\\/", "/")
        if url.startswith("//"):
            url = "https:" + url
        try:
            data = get(url)
        except Exception as e:
            return pid, f"img:{e}"
        open(dst, "wb").write(data)
        # ⚠️ 換算比は**取れたときだけ**記録する（先に書くと、失敗した写真の古い画像が
        # 「取得済み」と誤判定されて座標がずれる）。
        scales[pid] = best[1] / ref
        time.sleep(0.5)
        return pid, "ok"

    stats = defaultdict(int)
    with ThreadPoolExecutor(max_workers=2) as ex:
        for i, (pid, st) in enumerate(ex.map(fetch, chosen), 1):
            stats[st.split(":")[0]] += 1
            if i % 50 == 0:
                print(f"  {i}/{len(chosen)} {dict(stats)}", flush=True)
                json.dump(scales, open(scale_path, "w"))   # 途中で止めても取れた分を活かす
    print("取得:", dict(stats))
    json.dump(scales, open(scale_path, "w"))

    # 注釈は**取得した画像の画素**へ換算する。
    with open(os.path.join(args.out, "annotations.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["photo", "album", "date", "x", "y", "w", "h", "identity"])
        for pid in chosen:
            path = os.path.join(args.out, "images", f"{pid}.jpg")
            if not os.path.exists(path):
                continue
            if pid not in scales:
                continue
            scale = scales[pid]
            for x, y, ww, hh, ident in photos[pid]["heads"]:
                w.writerow([pid, photos[pid]["album"], photos[pid]["date"].isoformat(),
                            round(x * scale), round(y * scale), round(ww * scale), round(hh * scale), ident])
    print("annotations.csv を書いた")


if __name__ == "__main__":
    main()
