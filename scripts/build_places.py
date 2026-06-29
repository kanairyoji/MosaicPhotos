#!/usr/bin/env python3
"""GeoNames cities15000 から、オフライン逆ジオコーディング用のコンパクトなバイナリを生成する。

オンライン逆ジオコーディング（CLGeocoder）はレート制限＋要ネットワーク＋失敗時の不確実さがある。
都市の座標表（cities15000・約2.6万件）を同梱し、端末で最近傍検索することで、地名解決を
**完全オフライン・即時・無制限**にする（アルバム名／場所アルバムの両方に効く）。

出力: Packages/PhotoSourceKit/Sources/PhotoSourceKit/Places/cities15000.bin（リトルエンディアン）
  magic "MPC1"(4) / u32 version=1 / u32 N
  f32 lat[N] / f32 lon[N] / u16 adminIdx[N] / u16 countryIdx[N]
  u16 adminCount + adminCount×(u16 len + utf8)        # 行政区(都道府県/州)名プール
  u16 countryCount + countryCount×(u16 len + utf8)    # 国名プール
  N × (u16 len + utf8)                                 # 都市名（配列順）

データ: GeoNames (https://www.geonames.org/) — CC BY 4.0。NOTICE / アプリ内 Licenses に表記する。
"""
import io, os, struct, sys, urllib.request, zipfile

BASE = "https://download.geonames.org/export/dump/"
OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Packages/PhotoSourceKit/Sources/PhotoSourceKit/Places/cities15000.bin")


def fetch(name: str) -> bytes:
    url = BASE + name
    print(f"download {url}")
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def main() -> None:
    # 国コード→国名
    country = {}
    for line in fetch("countryInfo.txt").decode("utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        c = line.split("\t")
        if len(c) > 4 and c[0]:
            country[c[0]] = c[4]

    # "国.admin1コード" → 行政区名（都道府県/州）
    admin1 = {}
    for line in fetch("admin1CodesASCII.txt").decode("utf-8").splitlines():
        c = line.split("\t")
        if len(c) >= 2:
            admin1[c[0]] = c[1]

    # cities15000.zip（zip 内 cities15000.txt）
    zbytes = fetch("cities15000.zip")
    with zipfile.ZipFile(io.BytesIO(zbytes)) as z:
        txt = z.read("cities15000.txt").decode("utf-8")

    lats, lons, city_names = [], [], []
    admin_pool, admin_idx, admin_map = [], [], {}
    country_pool, country_idx, country_map = [], [], {}

    def intern(pool, mapping, value):
        i = mapping.get(value)
        if i is None:
            i = len(pool); pool.append(value); mapping[value] = i
        return i

    for line in txt.splitlines():
        c = line.split("\t")
        if len(c) < 11:
            continue
        name, lat, lon, cc, a1 = c[1], c[4], c[5], c[8], c[10]
        try:
            la, lo = float(lat), float(lon)
        except ValueError:
            continue
        lats.append(la); lons.append(lo); city_names.append(name)
        admin_idx.append(intern(admin_pool, admin_map, admin1.get(f"{cc}.{a1}", "")))
        country_idx.append(intern(country_pool, country_map, country.get(cc, cc)))

    n = len(lats)
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
    print(f"wrote {OUT}: {n} cities, {len(admin_pool)} admin, {len(country_pool)} countries, "
          f"{len(buf)/1024:.0f} KB")


if __name__ == "__main__":
    main()
