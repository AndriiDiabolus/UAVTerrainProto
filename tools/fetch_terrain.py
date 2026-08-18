#!/usr/bin/env python3
"""Скачивает рельеф (AWS Terrain Tiles, terrarium) и строит спутниковую подложку
(Sentinel-2 L2A COG, открытая лицензия Copernicus) для квадрата вокруг точки:
  godot/assets/height16.png  — 16-бит grayscale heightmap
  godot/assets/albedo.jpg    — спутниковая текстура (см. s2_albedo.py)
  godot/assets/meta.json     — min/max высот, размер в метрах, гео-привязка

Источники без ключей/регистрации:
  рельеф:   https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png
  подложка: sentinel-cogs (AWS Open Data) через Earth Search STAC — s2_albedo.py
            Copernicus Sentinel-2: открытая лицензия, коммерческое использование ОК.
Требует venv tools/.venv (numpy, pyproj, tifffile, imagecodecs, pillow).
"""
import io, json, math, sys, time
from array import array
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image

CENTER_LAT, CENTER_LON = 48.16, 24.50   # Говерла, Карпаты
Z_HEIGHT, N_HEIGHT = 13, 16              # 16x16 тайлов по 256px -> 4096px
ALBEDO_PX = 4096                         # размер подложки (Sentinel-2, ~12.7 м/px, native)
TILE = 256
EARTH = 40075016.686

ASSETS = Path(__file__).resolve().parent.parent / "godot" / "assets"
CACHE = Path(__file__).resolve().parent / "tile_cache"


def tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lat_r = math.radians(lat)
    y = (1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * n
    return x, y


def fetch(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return dest.read_bytes()
    for attempt in range(3):
        try:
            req = Request(url, headers={"User-Agent": "terrain-proto/0.1"})
            with urlopen(req, timeout=30) as r:
                data = r.read()
            dest.write_bytes(data)
            return data
        except Exception as e:
            if attempt == 2:
                raise RuntimeError(f"fail {url}: {e}")
            time.sleep(1 + attempt)


def build_mosaic(z, n_tiles, url_fmt, tag, mode):
    cx, cy = tile_xy(CENTER_LAT, CENTER_LON, z)
    x0, y0 = int(cx) - n_tiles // 2, int(cy) - n_tiles // 2
    mosaic = Image.new(mode, (n_tiles * TILE, n_tiles * TILE))
    jobs = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        for dy in range(n_tiles):
            for dx in range(n_tiles):
                x, y = x0 + dx, y0 + dy
                url = url_fmt.format(z=z, x=x, y=y)
                dest = CACHE / f"{tag}_{z}_{x}_{y}"
                jobs.append((dx, dy, ex.submit(fetch, url, dest)))
        done = 0
        for dx, dy, fut in jobs:
            img = Image.open(io.BytesIO(fut.result())).convert(mode)
            mosaic.paste(img, (dx * TILE, dy * TILE))
            done += 1
            if done % 32 == 0:
                print(f"  {tag}: {done}/{len(jobs)} тайлов", flush=True)
    return mosaic, x0, y0


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)

    print("Скачиваю рельеф (terrarium)...", flush=True)
    dem, hx0, hy0 = build_mosaic(
        Z_HEIGHT, N_HEIGHT,
        "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
        "dem", "RGB")

    print("Декодирую высоты...", flush=True)
    raw = dem.tobytes()
    n_px = dem.width * dem.height
    elev = array("f", bytes(4 * n_px))
    e_min, e_max = 1e9, -1e9
    for i in range(n_px):
        r, g, b = raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]
        e = r * 256.0 + g + b / 256.0 - 32768.0
        elev[i] = e
        if e < e_min: e_min = e
        if e > e_max: e_max = e

    span = max(e_max - e_min, 1.0)
    h16 = array("H", bytes(2 * n_px))
    for i in range(n_px):
        h16[i] = int((elev[i] - e_min) / span * 65535.0)
    Image.frombytes("I;16", dem.size, h16.tobytes()).save(ASSETS / "height16.png")
    (ASSETS / "height.raw").write_bytes(h16.tobytes())  # uint16 LE, для рантайм-загрузки в Godot
    print(f"  высоты: {e_min:.0f}..{e_max:.0f} м", flush=True)

    m_per_px = EARTH * math.cos(math.radians(CENTER_LAT)) / (TILE * 2 ** Z_HEIGHT)
    size_m = m_per_px * dem.width
    meta = {
        "center_lat": CENTER_LAT, "center_lon": CENTER_LON,
        "elev_min_m": round(e_min, 1), "elev_max_m": round(e_max, 1),
        "size_m": round(size_m, 1), "px": dem.width,
        "tile_x0": hx0, "tile_y0": hy0, "zoom": Z_HEIGHT, "n_tiles": N_HEIGHT,
    }

    print("Строю спутниковую подложку (Sentinel-2 L2A COG, открытая лицензия)...",
          flush=True)
    from s2_albedo import build_albedo
    img, attribution, coverage = build_albedo(meta, out_px=ALBEDO_PX)
    img.save(ASSETS / "albedo.jpg", quality=95)
    print(f"  подложка: {img.size[0]}px, покрытие {coverage*100:.1f}%", flush=True)

    meta["attribution"] = "Terrain: Mapzen/AWS Terrain Tiles; " + attribution
    (ASSETS / "meta.json").write_text(json.dumps(meta, indent=2))
    print(f"Готово: {size_m/1000:.1f} x {size_m/1000:.1f} км, {dem.width}px, "
          f"высоты {e_min:.0f}-{e_max:.0f} м", flush=True)


if __name__ == "__main__":
    sys.exit(main())
