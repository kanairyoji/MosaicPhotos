#!/usr/bin/env python3
"""GeoNames cities15000 から、オフライン逆ジオコーディング用のコンパクトなバイナリを生成する。

オンライン逆ジオコーディング（CLGeocoder）はレート制限＋要ネットワーク＋失敗時の不確実さがある。
都市の座標表（cities15000・約3.4万件）を同梱し、端末で最近傍検索することで、地名解決を
**完全オフライン・即時・無制限**にする（アルバム名／場所アルバムの両方に効く）。

地名は **日本語表記**を優先する：GeoNames の言語別別名（alternateNamesV2・isolanguage=ja）から
都市/都道府県/国の日本語名を取り込み、日本語名が無いものはローマ字（GeoNames の name）へフォールバックする。

出力: Packages/PhotoSourceKit/Sources/PhotoSourceKit/Places/cities15000.bin（リトルエンディアン）
  magic "MPC1"(4) / u32 version=1 / u32 N
  f32 lat[N] / f32 lon[N] / u16 adminIdx[N] / u16 countryIdx[N]
  u16 adminCount + adminCount×(u16 len + utf8)        # 行政区(都道府県/州)名プール
  u16 countryCount + countryCount×(u16 len + utf8)    # 国名プール
  N × (u16 len + utf8)                                 # 都市名（配列順）

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

    def localized(gid, fallback):
        v = ja.get(gid)
        return v[0] if v else fallback

    # 出力用配列＋プールを構築（日本語優先）。
    lats, lons, city_names = [], [], []
    admin_pool, admin_idx, admin_map = [], [], {}
    country_pool, country_idx, country_map = [], [], {}

    def intern(pool, mapping, value):
        i = mapping.get(value)
        if i is None:
            i = len(pool); pool.append(value); mapping[value] = i
        return i

    for gid, name, la, lo, cc, a1key in cities:
        lats.append(la); lons.append(lo)
        city_names.append(localized(gid, name))
        a_name, a_gid = admin1.get(a1key, ("", None))
        admin_idx.append(intern(admin_pool, admin_map, localized(a_gid, a_name) if a_gid else a_name))
        c_name, c_gid = country.get(cc, (cc, None))
        country_idx.append(intern(country_pool, country_map, localized(c_gid, c_name) if c_gid else c_name))

    n = len(lats)
    ja_cities = sum(1 for (gid, *_ ) in cities if gid in ja)
    if len(admin_pool) > 65535 or len(country_pool) > 65535:
        sys.exit("pool too large for u16 index")

    def pack_str(s: str) -> bytes:
        b = s.encode("utf-8")
        return struct.pack("<H", len(b)) + b

    buf = bytearray()
    buf += b"MPC1" + struct.pack("<II", 1, n)
    buf += struct.pack(f"<{n}f", *lats)
    buf += struct.pack(f"<{n}f", *lons)
    buf += struct.pack(f"<{n}H", *admin_idx)
    buf += struct.pack(f"<{n}H", *country_idx)
    buf += struct.pack("<H", len(admin_pool)) + b"".join(pack_str(s) for s in admin_pool)
    buf += struct.pack("<H", len(country_pool)) + b"".join(pack_str(s) for s in country_pool)
    buf += b"".join(pack_str(s) for s in city_names)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(buf)
    print(f"wrote {OUT}: {n} cities ({ja_cities} with {LANG} names), "
          f"{len(admin_pool)} admin, {len(country_pool)} countries, {len(buf)/1024:.0f} KB")


if __name__ == "__main__":
    main()
