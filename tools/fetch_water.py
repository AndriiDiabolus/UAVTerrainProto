#!/usr/bin/env python3
"""Качает реки/ручьи OSM для квадрата карты -> godot/assets/water.json"""
import os
import hashlib, json, math, time, urllib.request
from pathlib import Path

ASSETS = Path(os.environ["UAV_ASSETS"]) if os.environ.get("UAV_ASSETS") else Path(__file__).resolve().parent.parent / "godot" / "assets"
META = json.loads((ASSETS / "meta.json").read_text())
Z, N, X0, Y0, SIZE = META["zoom"], META["n_tiles"], META["tile_x0"], META["tile_y0"], META["size_m"]
TWO_Z = 2 ** Z
OSM_CACHE = Path(__file__).resolve().parent / "osm_cache"
OSM_CACHE.mkdir(exist_ok=True)

ENDPOINTS = ["https://overpass-api.de/api/interpreter",
             "https://z.overpass-api.de/api/interpreter",
             "https://lz4.overpass-api.de/api/interpreter",
             "https://overpass.kumi.systems/api/interpreter",
             "https://overpass.private.coffee/api/interpreter"]

def overpass(query):
    key = OSM_CACHE / (hashlib.md5(query.encode()).hexdigest() + ".json")
    if key.exists():
        return json.loads(key.read_text())
    for attempt in range(3):
        for ep in ENDPOINTS:
            try:
                req = urllib.request.Request(ep, data=query.encode(),
                    headers={"User-Agent": "terrain-proto/0.1"})
                with urllib.request.urlopen(req, timeout=300) as r:
                    data = json.loads(r.read())
                key.write_text(json.dumps(data))
                return data
            except Exception as e:
                print("  fail:", ep, str(e)[:60], flush=True)
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

ways = []
for i in range(3):
    for j in range(3):
        s_ = LAT_S + (LAT_N - LAT_S) * i / 3; n_ = LAT_S + (LAT_N - LAT_S) * (i + 1) / 3
        w_ = LON_W + (LON_E - LON_W) * j / 3; e_ = LON_W + (LON_E - LON_W) * (j + 1) / 3
        bb = f"{s_:.5f},{w_:.5f},{n_:.5f},{e_:.5f}"
        print(f"вода: тайл {i*3+j+1}/9", flush=True)
        data = overpass(f'[out:json][timeout:120];way["waterway"~"^(river|stream)$"]({bb});out geom;')
        ways += data.get("elements", [])
        time.sleep(1)

seen, out = set(), []
for el in ways:
    if el.get("id") in seen or "geometry" not in el:
        continue
    seen.add(el["id"])
    pts = []
    for g in el["geometry"]:
        x, z = world_xy(g["lat"], g["lon"])
        pts.append([round(x, 1), round(z, 1)])
    if len(pts) >= 2:
        out.append({"c": el["tags"].get("waterway", "stream"), "p": pts})
print("водотоков:", len(out))
(ASSETS / "water.json").write_text(json.dumps({"w": out}))
