#!/usr/bin/env python3
"""Собирает регион одной командой: рельеф + Sentinel-2 + OSM (дороги/дома/реки/озёра) + запечка.

  tools/.venv/bin/python tools/build_region.py --name steppe --lat 47.66 --lon 33.72
  tools/.venv/bin/python tools/build_region.py --name steppe --lat 47.66 --lon 33.72 --start 47.70,33.75

Результат: godot/assets/regions/<name>/ (height.raw, meta.json, albedo.jpg, mask.png,
roads.json, buildings.json, water.json, lakes.json). Запуск: ./run.sh --region=<name>.
Регион по умолчанию (Карпаты) живёт прямо в godot/assets/.

Шаги можно пропускать: --skip terrain,osm,water,lakes,landcover,bake. Кеши (tile_cache/, osm_cache/) общие.
Объём загрузки на регион 52×52 км: DEM ~5 МБ, Sentinel-2 TCI 2–7 сцен по 100–300 МБ, OSM 10–60 МБ.
"""
import argparse, os, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PY = sys.executable

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True, help="имя региона (латиницей, без пробелов)")
ap.add_argument("--lat", type=float, required=True)
ap.add_argument("--lon", type=float, required=True)
ap.add_argument("--start", default="", help="точка старта дрона lat,lon (по умолчанию центр)")
ap.add_argument("--skip", default="", help="через запятую: terrain,osm,water,lakes,bake")
ap.add_argument("--godot", default=os.environ.get("GODOT", ""), help="бинарь Godot для импорта ресурсов после сборки")
a = ap.parse_args()

skip = {s.strip() for s in a.skip.split(",") if s.strip()}
assets = ROOT / "godot" / "assets" / "regions" / a.name
assets.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, UAV_ASSETS=str(assets), UAV_LAT=str(a.lat), UAV_LON=str(a.lon), UAV_REGION=a.name)
if a.start:
    la, lo = a.start.split(",")
    env["UAV_START_LAT"] = la.strip(); env["UAV_START_LON"] = lo.strip()


def run(step, script):
    if step in skip:
        print(f"— {step}: пропуск"); return
    t0 = time.time()
    print(f"=== {step}: {script} ===", flush=True)
    r = subprocess.run([PY, str(HERE / script)], env=env, cwd=str(HERE))
    if r.returncode != 0:
        print(f"!!! {step} завершился с кодом {r.returncode}"); sys.exit(r.returncode)
    print(f"=== {step}: {time.time() - t0:.0f} с ===", flush=True)


run("terrain", "fetch_terrain.py")   # height.raw, meta.json, albedo.jpg
run("osm", "fetch_osm.py")           # roads.json, buildings.json
run("water", "fetch_water.py")       # water.json
run("lakes", "fetch_lakes.py")       # lakes.json
run("landcover", "fetch_landcover.py")  # landcover.png (ESA WorldCover 10 м, ~10 МБ через HTTP-Range)
run("bake", "bake_overlay.py")       # albedo.jpg (+дороги/реки), mask.png, albedo_clean.jpg

# импорт ресурсов Godot (albedo.jpg/mask.png → .import), чтобы регион грузился через load()
godot = a.godot or "/Users/andriidiablo/Desktop/Sabbath_3D/Godot.app/Contents/MacOS/Godot"
if Path(godot).exists():
    print("=== импорт ресурсов Godot ===", flush=True)
    subprocess.run([godot, "--headless", "--path", str(ROOT / "godot"), "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"Регион '{a.name}' готов: {assets}\nЗапуск: ./run.sh --region={a.name}")
