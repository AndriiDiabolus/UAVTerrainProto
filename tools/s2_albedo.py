#!/usr/bin/env python3
"""Строит спутниковую подложку (albedo) из Sentinel-2 L2A COG'ов открытого
бакета sentinel-cogs (AWS Open Data, Copernicus Sentinel — открытая лицензия,
коммерческое использование разрешено с указанием источника).

В отличие от EOX s2cloudless (CC-BY-NC), эти данные годятся для продакшена.

Читает готовый True-Color COG (asset "visual" = TCI.tif) через tifffile
(без GDAL), репроецирует из UTM в Web Mercator под точный extent DEM-мозаики
и, при необходимости, домозаичивает второй сценой (наш AOI лежит на границе
UTM-зон 34/35). Требует venv: numpy, pyproj, tifffile, imagecodecs, pillow.

Использование — из fetch_terrain.py: build_albedo(meta) -> PIL.Image (RGB).
Автономный тест: python s2_albedo.py [--px N] [--preview]
"""
import io
import json
import math
import sys
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageFilter
from pyproj import Transformer

EARTH = 40075016.686
R = EARTH / 2.0  # полу-обхват Web Mercator, м
STAC = "https://earth-search.aws.element84.com/v1/search"
CACHE = Path(__file__).resolve().parent / "tile_cache"
CLOUD_MAX = 10.0          # % облачности для отбора сцен
DATE_RANGE = "2023-05-01T00:00:00Z/2025-09-20T23:59:59Z"  # безоблачный тёплый сезон


def merc_bounds(tile_x0, tile_y0, z, n_tiles):
    """3857-границы DEM-мозаики (xmin, ymin, xmax, ymax)."""
    tile_m = EARTH / (2 ** z)
    xmin = -R + tile_x0 * tile_m
    xmax = xmin + n_tiles * tile_m
    ymax = R - tile_y0 * tile_m
    ymin = ymax - n_tiles * tile_m
    return xmin, ymin, xmax, ymax


def stac_search(lat, lon):
    d = 0.02
    body = {
        "collections": ["sentinel-2-l2a"],
        "bbox": [lon - d, lat - d, lon + d, lat + d],
        "datetime": DATE_RANGE,
        "limit": 100,
    }
    req = urllib.request.Request(
        STAC, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        feats = json.load(r).get("features", [])
    feats = [f for f in feats
             if (f["properties"].get("eo:cloud_cover", 100) or 100) <= CLOUD_MAX]
    feats.sort(key=lambda f: f["properties"].get("eo:cloud_cover", 100))
    return feats


def download(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "terrain-proto/0.2"})
    with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    tmp.rename(dest)
    return dest


def read_tci(path, target_mpp):
    """Читает TCI COG: выбирает уровень (overview) не грубее target_mpp.
    Возвращает (rgb uint8 [H,W,3], affine (ulx, uly, px), epsg)."""
    with tifffile.TiffFile(path) as tif:
        page0 = tif.pages[0]
        tags = page0.tags
        scale = tags["ModelPixelScaleTag"].value
        tiepoint = tags["ModelTiepointTag"].value  # i,j,k, X,Y,Z
        px0 = float(scale[0])
        ulx = float(tiepoint[3]) - float(tiepoint[0]) * px0
        uly = float(tiepoint[4]) + float(tiepoint[1]) * float(scale[1])
        # EPSG из GeoKeyDirectory (ProjectedCSTypeGeoKey=3072)
        epsg = None
        gk = tags.get("GeoKeyDirectoryTag")
        if gk is not None:
            v = gk.value
            for i in range(4, len(v), 4):
                if v[i] == 3072:
                    epsg = int(v[i + 3])
                    break
        levels = tif.series[0].levels
        chosen = 0
        for li, lvl in enumerate(levels):
            factor = page0.imagewidth / lvl.shape[-1] if lvl.shape[-1] else 1
            if px0 * factor <= target_mpp:
                chosen = li
        lvl = levels[chosen]
        arr = lvl.asarray()
        factor = page0.imagewidth / arr.shape[1]
        eff_px = px0 * factor
    if arr.ndim == 3 and arr.shape[0] in (3, 4):  # bands-first -> H,W,C
        arr = np.moveaxis(arr, 0, -1)
    arr = arr[:, :, :3]
    return arr, (ulx, uly, eff_px), epsg


def build_albedo(meta, out_px=4096, verbose=True):
    lat, lon = meta["center_lat"], meta["center_lon"]
    xmin, ymin, xmax, ymax = merc_bounds(
        meta["tile_x0"], meta["tile_y0"], meta["zoom"], meta["n_tiles"])

    # Целевая сетка в 3857 (пиксель [0,0] — верх-лево, y убывает вниз)
    xs = xmin + (np.arange(out_px) + 0.5) * (xmax - xmin) / out_px
    ys = ymax - (np.arange(out_px) + 0.5) * (ymax - ymin) / out_px
    gx, gy = np.meshgrid(xs, ys)
    to4326 = Transformer.from_crs(3857, 4326, always_xy=True)
    tlon, tlat = to4326.transform(gx, gy)

    target_mpp = (xmax - xmin) * math.cos(math.radians(lat)) / out_px
    out = np.zeros((out_px, out_px, 3), np.uint8)
    filled = np.zeros((out_px, out_px), bool)

    feats = stac_search(lat, lon)
    if not feats:
        raise RuntimeError("STAC: не найдено безоблачных сцен для AOI")
    if verbose:
        print(f"  найдено сцен (cloud<={CLOUD_MAX}%): {len(feats)}", flush=True)

    used = []
    for f in feats:
        if filled.all():
            break
        href = f["assets"]["visual"]["href"]
        sid = f["id"]
        dest = CACHE / f"tci_{sid}.tif"
        if verbose:
            print(f"  сцена {sid} cloud={f['properties'].get('eo:cloud_cover'):.1f}%"
                  f" — качаю TCI…", flush=True)
        try:
            download(href, dest)
            arr, (ulx, uly, eff_px), epsg = read_tci(dest, target_mpp)
        except (urllib.error.URLError, KeyError, OSError) as e:
            if verbose:
                print(f"    пропуск ({e})", flush=True)
            continue
        H, W = arr.shape[:2]
        to_utm = Transformer.from_crs(4326, epsg, always_xy=True)
        need = ~filled
        ux, uy = to_utm.transform(tlon[need], tlat[need])
        col = ((ux - ulx) / eff_px).astype(np.int64)
        row = ((uly - uy) / eff_px).astype(np.int64)
        inb = (col >= 0) & (col < W) & (row >= 0) & (row < H)
        if not inb.any():
            continue
        sample = np.zeros((need.sum(), 3), np.uint8)
        valid = np.zeros(need.sum(), bool)
        ci, ri = col[inb], row[inb]
        px_rgb = arr[ri, ci]
        nonblack = px_rgb.any(axis=1)  # 0,0,0 = nodata за пределами снимка
        idx_inb = np.where(inb)[0]
        sample[idx_inb] = px_rgb
        valid[idx_inb] = nonblack
        ny, nx = np.where(need)
        sy, sx = ny[valid], nx[valid]
        out[sy, sx] = sample[valid]
        filled[sy, sx] = True
        used.append((sid, epsg, eff_px))
        if verbose:
            print(f"    заполнено {filled.mean()*100:.1f}% (epsg {epsg},"
                  f" {eff_px:.1f} м/px)", flush=True)

    if not used:
        raise RuntimeError("не удалось прочитать ни одной сцены")
    img = Image.fromarray(out, "RGB").filter(
        ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))
    attribution = ("Imagery: Copernicus Sentinel-2 L2A (" +
                   ", ".join(s for s, _, _ in used) +
                   "), open licence, via AWS sentinel-cogs")
    return img, attribution, filled.mean()


def main():
    px = 1024
    preview = "--preview" in sys.argv
    if "--px" in sys.argv:
        px = int(sys.argv[sys.argv.index("--px") + 1])
    meta = json.loads((Path(__file__).resolve().parent.parent /
                       "godot" / "assets" / "meta.json").read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    img, attr, cov = build_albedo(meta, out_px=px)
    print(f"coverage {cov*100:.1f}%  |  {attr}")
    if preview:
        p = Path(__file__).resolve().parent.parent / "albedo_s2_preview.jpg"
        img.save(p, quality=90)
        print("preview ->", p)


if __name__ == "__main__":
    sys.exit(main())
