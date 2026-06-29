#!/usr/bin/env python3
"""GeoNames cities15000 から、オフライン逆ジオコーディング用のコンパクトなバイナリを生成する。

オンライン逆ジオコーディング（CLGeocoder）はレート制限＋要ネットワーク＋失敗時の不確実さがある。
都市の座標表（cities15000・約3.4万件）を同梱し、端末で最近傍検索することで、地名解決を
**完全オフライン・即時・無制限**にする（アルバム名／場所アルバムの両方に効く）。

地名は **英語（ローマ字）と日本語の両方**を持たせ、アプリ側が端末/設定の言語に応じて選ぶ。
英語＝GeoNames の name（ローマ字）、日本語＝言語別別名 alternateNamesV2（isolanguage=ja）。
日本語名が無い都市は ja を空にし、アプリ側で英語へフォールバックする。

出力: Packages/PhotoSourceKit/Sources/PhotoSourceKit/Places/cities15000.bin（リトルエンディアン）
  magic "MPC2"(4) / u32 version=2 / u32 N
  f32 lat[N] / f32 lon[N]
  u16 adminEnIdx[N] / u16 adminJaIdx[N] / u16 countryEnIdx[N] / u16 countryJaIdx[N]
  4 プール（adminEn / adminJa / countryEn / countryJa）：各 u16 count + count×(u16 len + utf8)
  N×(u16 len + utf8) cityEn  ＋  N×(u16 len + utf8) cityJa（空＝英語へフォールバック）

データ: GeoNames (https://www.geonames.org/) — CC BY 4.0。NOTICE / アプリ内 Licenses に表記する。
"""
import io, os, struct, sys, tempfile, urllib.request, zipfile

BASE = "https://download.geonames.org/export/dump/"
OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Packages/PhotoSourceKit/Sources/PhotoSourceKit/Places/cities15000.bin")
CACHE = os.path.join(tempfile.gettempdir(), "geonames_cache")
LANG = "ja"   # 優先する表示言語


def cached(name: str) -> str:
    """ダウンロードしてローカルキャッシュに置き、パスを返す（再実行時は再DLしない）。"""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        url = BASE + name
        print(f"download {url}")
        urllib.request.urlretrieve(url, path)
    return path


def main() -> None:
    needed = set()   # 日本語名を引きたい geonameid（都市・都道府県・国）

    # 国コード→(英名, geonameid)
    country = {}
    with open(cached("countryInfo.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            c = line.rstrip("\n").split("\t")
            if len(c) > 16 and c[0]:
                gid = int(c[16]) if c[16].isdigit() else None
                country[c[0]] = (c[4], gid)
                if gid:
                    needed.add(gid)

    # "国.admin1コード" → (英名, geonameid)
    admin1 = {}
    with open(cached("admin1CodesASCII.txt"), encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) >= 4:
                gid = int(c[3]) if c[3].isdigit() else None
                admin1[c[0]] = (c[1], gid)
                if gid:
                    needed.add(gid)

    # cities15000（座標・英名・国・admin1・geonameid）
    with zipfile.ZipFile(cached("cities15000.zip")) as z:
        cities_rows = z.read("cities15000.txt").decode("utf-8").splitlines()
    cities = []   # (gid, name, lat, lon, cc, a1key)
    for line in cities_rows:
        c = line.split("\t")
        if len(c) < 11:
            continue
        try:
            gid, la, lo = int(c[0]), float(c[4]), float(c[5])
        except ValueError:
            continue
        cities.append((gid, c[1], la, lo, c[8], f"{c[8]}.{c[10]}"))
        needed.add(gid)

    # alternateNamesV2 から日本語名を抽出（必要 geonameid のみ・isPreferred>isShort を優先）。
    ja = {}   # gid -> (name, score)
    print(f"scan alternateNames for '{LANG}' (needed gids: {len(needed)}) ...")
    with zipfile.ZipFile(cached("alternateNamesV2.zip")) as z:
        with z.open("alternateNamesV2.txt") as raw:
            for line in io.TextIOWrapper(raw, encoding="utf-8"):
                c = line.rstrip("\n").split("\t")
                if len(c) < 4 or c[2] != LANG:
                    continue
                if not c[1].isdigit():
                    continue
                gid = int(c[1])
                if gid not in needed:
                    continue
                is_pref = len(c) > 4 and c[4] == "1"
                is_short = len(c) > 5 and c[5] == "1"
                is_colloq = len(c) > 6 and c[6] == "1"
                is_hist = len(c) > 7 and c[7] == "1"
                if is_colloq or is_hist:
                    continue
                score = (2 if is_pref else 0) + (1 if is_short else 0)
                cur = ja.get(gid)
                if cur is None or score > cur[1]:
                    ja[gid] = (c[3], score)

    def ja_or_empty(gid):
        v = ja.get(gid)
        return v[0] if v else ""

    # 出力用配列＋プールを構築（英語＝GeoNames name のローマ字、日本語＝alternateNames ja・無ければ空）。
    # 端末/設定の言語に応じてアプリ側が en/ja を選ぶ（ja が空なら en へフォールバック）。
    lats, lons, city_en, city_ja = [], [], [], []
    pools = {k: ([], {}) for k in ("aen", "aja", "cen", "cja")}   # name pool + intern map

    def intern(key, value):
        pool, mapping = pools[key]
        i = mapping.get(value)
        if i is None:
            i = len(pool); pool.append(value); mapping[value] = i
        return i

    admin_en_idx, admin_ja_idx, country_en_idx, country_ja_idx = [], [], [], []
    for gid, name, la, lo, cc, a1key in cities:
        lats.append(la); lons.append(lo)
        city_en.append(name)
        city_ja.append(ja_or_empty(gid))
        a_name, a_gid = admin1.get(a1key, ("", None))
        admin_en_idx.append(intern("aen", a_name))
        admin_ja_idx.append(intern("aja", ja_or_empty(a_gid) if a_gid else ""))
        c_name, c_gid = country.get(cc, (cc, None))
        country_en_idx.append(intern("cen", c_name))
        country_ja_idx.append(intern("cja", ja_or_empty(c_gid) if c_gid else ""))

    n = len(lats)
    ja_cities = sum(1 for s in city_ja if s)
    for k in pools:
        if len(pools[k][0]) > 65535:
            sys.exit(f"pool {k} too large for u16 index")

    def pack_str(s: str) -> bytes:
        b = s.encode("utf-8")
        return struct.pack("<H", len(b)) + b

    def pack_pool(key) -> bytes:
        pool = pools[key][0]
        return struct.pack("<H", len(pool)) + b"".join(pack_str(s) for s in pool)

    buf = bytearray()
    buf += b"MPC2" + struct.pack("<II", 2, n)
    buf += struct.pack(f"<{n}f", *lats)
    buf += struct.pack(f"<{n}f", *lons)
    buf += struct.pack(f"<{n}H", *admin_en_idx)
    buf += struct.pack(f"<{n}H", *admin_ja_idx)
    buf += struct.pack(f"<{n}H", *country_en_idx)
    buf += struct.pack(f"<{n}H", *country_ja_idx)
    buf += pack_pool("aen") + pack_pool("aja") + pack_pool("cen") + pack_pool("cja")
    buf += b"".join(pack_str(s) for s in city_en)
    buf += b"".join(pack_str(s) for s in city_ja)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(buf)
    print(f"wrote {OUT}: {n} cities ({ja_cities} with {LANG} names), "
          f"admin en/ja={len(pools['aen'][0])}/{len(pools['aja'][0])}, "
          f"country en/ja={len(pools['cen'][0])}/{len(pools['cja'][0])}, {len(buf)/1024:.0f} KB")


if __name__ == "__main__":
    main()
