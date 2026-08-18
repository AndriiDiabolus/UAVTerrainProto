#!/usr/bin/env python3
"""Качает водоёмы OSM (natural=water, landuse=reservoir) -> godot/assets/lakes.json
Полигоны в локальных метрах мира."""
import os
import hashlib, json, math, time, urllib.request
from pathlib import Path

ASSETS = Path(os.environ["UAV_ASSETS"]) if os.environ.get("UAV_ASSETS") else Path(__file__).resolve().parent.parent / "godot" / "assets"
META = json.loads((ASSETS / "meta.json").read_text())
Z, N, X0, Y0, SIZE = META["zoom"], META["n_tiles"], META["tile_x0"], META["tile_y0"], META["size_m"]
TWO_Z = 2 ** Z
CACHE = Path(__file__).resolve().parent / "osm_cache"
CACHE.mkdir(exist_ok=True)

ENDPOINTS = ["https://overpass-api.de/api/interpreter",
             "https://z.overpass-api.de/api/interpreter",
             "https://lz4.overpass-api.de/api/interpreter",
             "https://overpass.kumi.systems/api/interpreter",
             "https://overpass.private.coffee/api/interpreter"]


def overpass(query):
    key = CACHE / (hashlib.md5(query.encode()).hexdigest() + ".json")
    if key.exists():
        return json.loads(key.read_text())
    for _ in range(3):
        for ep in ENDPOINTS:
            try:
                req = urllib.request.Request(ep, data=query.encode(),
                                             headers={"User-Agent": "terrain-proto/0.1"})
                with urllib.request.urlopen(req, timeout=300) as r:
                    data = json.loads(r.read())
                key.write_text(json.dumps(data))
                return data
            except Exception as e:
                print("  fail:", ep.split("//")[1][:22], str(e)[:50], flush=True)
                time.sleep(4)
        time.sleep(15)
    raise RuntimeError("overpass failed")


def inv_lat(ty):
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / TWO_Z))))


def world_xy(lat, lon):
    tx = (lon + 180.0) / 360.0 * TWO_Z
    lr = math.radians(lat)
    ty = (1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * TWO_Z
    return (((tx - X0) / N) - 0.5) * SIZE, (((ty - Y0) / N) - 0.5) * SIZE


LAT_N, LAT_S = inv_lat(Y0), inv_lat(Y0 + N)
LON_W, LON_E = X0 / TWO_Z * 360 - 180, (X0 + N) / TWO_Z * 360 - 180

elems = []
for i in range(2):
    for j in range(2):
        s_ = LAT_S + (LAT_N - LAT_S) * i / 2; n_ = LAT_S + (LAT_N - LAT_S) * (i + 1) / 2
        w_ = LON_W + (LON_E - LON_W) * j / 2; e_ = LON_W + (LON_E - LON_W) * (j + 1) / 2
        bb = f"{s_:.5f},{w_:.5f},{n_:.5f},{e_:.5f}"
        print(f"водоёмы: тайл {i*2+j+1}/4", flush=True)
        q = f'[out:json][timeout:120];(way["natural"="water"]({bb});way["landuse"="reservoir"]({bb}););out geom;'
        elems += overpass(q).get("elements", [])
        time.sleep(1)

seen, out = set(), []
for el in elems:
    if el.get("id") in seen or "geometry" not in el:
        continue
    seen.add(el["id"])
    pts = [world_xy(g["lat"], g["lon"]) for g in el["geometry"]]
    if len(pts) < 4:
        continue
    # площадь по формуле шнурков — отсечь микроскопические
    a = abs(sum(pts[k][0] * pts[(k + 1) % len(pts)][1] - pts[(k + 1) % len(pts)][0] * pts[k][1]
                for k in range(len(pts)))) / 2.0
    if a < 200.0:
        continue
    out.append([[round(p[0], 1), round(p[1], 1)] for p in pts])

print("водоёмов:", len(out))
(ASSETS / "lakes.json").write_text(json.dumps({"a": out}))
