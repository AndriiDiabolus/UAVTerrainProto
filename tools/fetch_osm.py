#!/usr/bin/env python3
"""Качает из OSM Overpass дороги и здания для квадрата карты (по meta.json),
переводит в локальные метры мира Godot и сохраняет:
  godot/assets/roads.json     — полилинии дорог по классам
  godot/assets/buildings.json — [x, z, w, d, angle, h] для каждого здания
"""
import json, math, sys, time, urllib.request
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "godot" / "assets"
META = json.loads((ASSETS / "meta.json").read_text())

Z = META["zoom"]; N = META["n_tiles"]
X0 = META["tile_x0"]; Y0 = META["tile_y0"]
SIZE = META["size_m"]
TWO_Z = 2 ** Z

def tile_frac(lat, lon):
    tx = (lon + 180.0) / 360.0 * TWO_Z
    lr = math.radians(lat)
    ty = (1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * TWO_Z
    return tx, ty

def world_xy(lat, lon):
    tx, ty = tile_frac(lat, lon)
    return (((tx - X0) / N) - 0.5) * SIZE, (((ty - Y0) / N) - 0.5) * SIZE

def inv_lat(ty):
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / TWO_Z))))

LAT_N = inv_lat(Y0); LAT_S = inv_lat(Y0 + N)
LON_W = X0 / TWO_Z * 360 - 180; LON_E = (X0 + N) / TWO_Z * 360 - 180
BBOX = f"{LAT_S:.5f},{LON_W:.5f},{LAT_N:.5f},{LON_E:.5f}"
print("bbox:", BBOX)

OSM_CACHE = Path(__file__).resolve().parent / "osm_cache"
OSM_CACHE.mkdir(exist_ok=True)

ENDPOINTS = ["https://overpass-api.de/api/interpreter",
             "https://z.overpass-api.de/api/interpreter",
             "https://lz4.overpass-api.de/api/interpreter",
             "https://overpass.kumi.systems/api/interpreter",
             "https://overpass.private.coffee/api/interpreter"]

def overpass(query):
    import hashlib
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
                print("  endpoint fail:", ep, str(e)[:80], flush=True)
                time.sleep(5)
        print(f"  круг {attempt+1} не удался, пауза 20с...", flush=True)
        time.sleep(20)
    raise RuntimeError("all overpass endpoints failed")

def grid_bboxes(nsplit):
    bbs = []
    for i in range(nsplit):
        for j in range(nsplit):
            s_ = LAT_S + (LAT_N - LAT_S) * i / nsplit
            n_ = LAT_S + (LAT_N - LAT_S) * (i + 1) / nsplit
            w_ = LON_W + (LON_E - LON_W) * j / nsplit
            e_ = LON_W + (LON_E - LON_W) * (j + 1) / nsplit
            bbs.append(f"{s_:.5f},{w_:.5f},{n_:.5f},{e_:.5f}")
    return bbs

def fetch_grid(qtpl, nsplit=3):
    seen, elements = set(), []
    for k, bb in enumerate(grid_bboxes(nsplit)):
        print(f"  тайл {k+1}/{nsplit*nsplit}...", flush=True)
        data = overpass(qtpl.format(bb=bb))
        for el in data.get("elements", []):
            if el.get("id") not in seen:
                seen.add(el.get("id"))
                elements.append(el)
        time.sleep(1)
    return elements

# --- дороги ---
print("Качаю дороги...", flush=True)
els = fetch_grid('[out:json][timeout:120];way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|track)$"]({bb});out geom;')
roads = []
for el in els:
    if el.get("type") != "way" or "geometry" not in el:
        continue
    cls = el["tags"]["highway"]
    pts = []
    for g in el["geometry"]:
        x, z = world_xy(g["lat"], g["lon"])
        pts.append([round(x, 1), round(z, 1)])
    if len(pts) >= 2:
        roads.append({"c": cls, "p": pts})
print(f"  дорог: {len(roads)}", flush=True)
(ASSETS / "roads.json").write_text(json.dumps({"roads": roads}))

# --- здания ---
print("Качаю здания...", flush=True)
els = fetch_grid('[out:json][timeout:120];way["building"]({bb});out geom;')
blds = []
for el in els:
    if el.get("type") != "way" or "geometry" not in el:
        continue
    pts = [world_xy(g["lat"], g["lon"]) for g in el["geometry"]]
    if len(pts) < 3:
        continue
    xs = [p[0] for p in pts]; zs = [p[1] for p in pts]
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    # угол по самому длинному ребру
    best_len, ang = 0.0, 0.0
    for i in range(len(pts) - 1):
        dx = pts[i+1][0] - pts[i][0]; dz = pts[i+1][1] - pts[i][1]
        l2 = dx*dx + dz*dz
        if l2 > best_len:
            best_len = l2; ang = math.atan2(dz, dx)
    # габариты в осях ребра
    ca, sa = math.cos(-ang), math.sin(-ang)
    us = [ (p[0]-cx)*ca - (p[1]-cz)*sa for p in pts ]
    vs = [ (p[0]-cx)*sa + (p[1]-cz)*ca for p in pts ]
    w = max(us) - min(us); d = max(vs) - min(vs)
    if w < 2 or d < 2 or w > 300 or d > 300:
        continue
    tags = el.get("tags", {})
    h = 0.0
    try:
        h = float(str(tags.get("height", "")).split()[0])
    except (ValueError, IndexError):
        pass
    if h <= 0:
        try:
            h = float(tags.get("building:levels", 0)) * 3.2
        except ValueError:
            h = 0.0
    if h <= 0:
        h = 5.0 + (hash((round(cx), round(cz))) % 100) / 40.0  # 5.0..7.5
    blds.append([round(cx,1), round(cz,1), round(w,1), round(d,1), round(ang,3), round(h,1)])
print(f"  зданий: {len(blds)}", flush=True)
(ASSETS / "buildings.json").write_text(json.dumps({"b": blds}))
print("Готово.", flush=True)
