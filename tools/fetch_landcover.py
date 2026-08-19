#!/usr/bin/env python3
"""ESA WorldCover 10 м (2021 v200, CC BY 4.0) → godot/assets/landcover.png (L8, коды классов) в сетке карты.

Читает нужные тайлы COG напрямую с S3 через HTTP Range (качается только окно AOI, а не тайл 3°×3° целиком).
Коды WorldCover: 10 лес, 20 кустарник, 30 луг, 40 пашня, 50 застройка, 60 голая земля, 70 снег/лёд,
80 вода, 90 болото, 95 мангры, 100 мох/лишайник (тундра/полонина).
Использует ASSETS/meta.json (UAV_ASSETS), пишет landcover.png 4096² — потом bake_overlay.py строит mask.png.
"""
import io, json, math, os, sys, urllib.request
from pathlib import Path
import numpy as np
import tifffile
from PIL import Image

ASSETS = Path(os.environ["UAV_ASSETS"]) if os.environ.get("UAV_ASSETS") else Path(__file__).resolve().parent.parent / "godot" / "assets"
META = json.loads((ASSETS / "meta.json").read_text())
CACHE = Path(__file__).resolve().parent / "tile_cache"
CACHE.mkdir(exist_ok=True)
BASE = "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_{tile}_Map.tif"
OUT_PX = 4096


class RangeFile(io.RawIOBase):
    """Файл по HTTP с Range-запросами и кешем блоков по 1 МБ (для tifffile)."""
    BLOCK = 1 << 20
    def __init__(self, url):
        self.url = url; self.pos = 0; self.cache = {}; self.fetched = 0
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "terrain-proto/0.3"})
        with urllib.request.urlopen(req, timeout=60) as r:
            self.size = int(r.headers["Content-Length"])
    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        if whence == 0: self.pos = off
        elif whence == 1: self.pos += off
        else: self.pos = self.size + off
        return self.pos
    def _block(self, i):
        if i not in self.cache:
            a = i * self.BLOCK; b = min(self.size, a + self.BLOCK) - 1
            req = urllib.request.Request(self.url, headers={"Range": f"bytes={a}-{b}", "User-Agent": "terrain-proto/0.3"})
            with urllib.request.urlopen(req, timeout=120) as r:
                self.cache[i] = r.read()
            self.fetched += len(self.cache[i])
        return self.cache[i]
    def read(self, n=-1):
        if n < 0: n = self.size - self.pos
        out = bytearray()
        while n > 0 and self.pos < self.size:
            i, o = divmod(self.pos, self.BLOCK)
            blk = self._block(i)
            chunk = blk[o:o + n]
            out += chunk; self.pos += len(chunk); n -= len(chunk)
            if not chunk: break
        return bytes(out)
    def readinto(self, b):
        data = self.read(len(b)); b[:len(data)] = data; return len(data)


def tile_name(lat, lon):
    la = int(math.floor(lat / 3.0) * 3); lo = int(math.floor(lon / 3.0) * 3)
    return f"{'N' if la >= 0 else 'S'}{abs(la):02d}{'E' if lo >= 0 else 'W'}{abs(lo):03d}"


def read_window(url, lat_n, lat_s, lon_w, lon_e):
    """Возвращает (arr uint8, lat0, lon0, px_deg) для окна из тайла (только нужные COG-тайлы 1024²)."""
    f = RangeFile(url)
    with tifffile.TiffFile(f) as tif:
        page = tif.pages[0]
        tags = page.tags
        scale = tags["ModelPixelScaleTag"].value; tp = tags["ModelTiepointTag"].value
        pxd = float(scale[0]); lon0 = float(tp[3]); lat0 = float(tp[4])
        W, H = page.imagewidth, page.imagelength
        tw, th = page.tilewidth, page.tilelength
        c0 = max(0, int((lon_w - lon0) / pxd)); c1 = min(W, int(math.ceil((lon_e - lon0) / pxd)))
        r0 = max(0, int((lat0 - lat_n) / pxd)); r1 = min(H, int(math.ceil((lat0 - lat_s) / pxd)))
        if c1 <= c0 or r1 <= r0:
            return None
        tiles_x = (W + tw - 1) // tw
        out = np.zeros((r1 - r0, c1 - c0), np.uint8)
        fh = tif.filehandle
        seg_i = 0
        for ty in range(r0 // th, (r1 - 1) // th + 1):
            for tx in range(c0 // tw, (c1 - 1) // tw + 1):
                idx = ty * tiles_x + tx
                off = page.dataoffsets[idx]; cnt = page.databytecounts[idx]
                if cnt == 0:
                    continue
                fh.seek(off); data = fh.read(cnt)
                seg = page.decode(data, idx)[0]
                seg = np.asarray(seg).reshape(th, tw, -1)[:, :, 0]
                ya, yb = ty * th, min((ty + 1) * th, H); xa, xb = tx * tw, min((tx + 1) * tw, W)
                sy0 = max(ya, r0); sy1 = min(yb, r1); sx0 = max(xa, c0); sx1 = min(xb, c1)
                out[sy0 - r0:sy1 - r0, sx0 - c0:sx1 - c0] = seg[sy0 - ya:sy1 - ya, sx0 - xa:sx1 - xa]
                seg_i += 1
        print(f"  {url.split('_')[-2]}: окно {out.shape[1]}×{out.shape[0]} px, COG-тайлов {seg_i}, скачано {f.fetched/1e6:.1f} МБ", flush=True)
        return out, lat0 - r0 * pxd, lon0 + c0 * pxd, pxd


def main():
    Z = META["zoom"]; N = META["n_tiles"]; X0 = META["tile_x0"]; Y0 = META["tile_y0"]; SIZE = META["size_m"]
    TWO_Z = 2 ** Z
    def inv_lat(ty): return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / TWO_Z))))
    LAT_N, LAT_S = inv_lat(Y0), inv_lat(Y0 + N)
    LON_W, LON_E = X0 / TWO_Z * 360 - 180, (X0 + N) / TWO_Z * 360 - 180
    print(f"AOI lat {LAT_S:.3f}..{LAT_N:.3f}, lon {LON_W:.3f}..{LON_E:.3f}", flush=True)
    # сетка выхода: Web Mercator пиксели карты → lat/lon
    ty = Y0 + (np.arange(OUT_PX) + 0.5) / OUT_PX * N
    tx = X0 + (np.arange(OUT_PX) + 0.5) / OUT_PX * N
    lats = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * ty / TWO_Z))))
    lons = tx / TWO_Z * 360 - 180
    out = np.zeros((OUT_PX, OUT_PX), np.uint8)
    tiles = sorted({tile_name(la, lo) for la in (LAT_S, LAT_N) for lo in (LON_W, LON_E)})
    print("тайлы WorldCover:", tiles, flush=True)
    for t in tiles:
        res = read_window(BASE.format(tile=t), LAT_N, LAT_S, LON_W, LON_E)
        if res is None:
            continue
        arr, lat0, lon0, pxd = res
        rows = ((lat0 - lats) / pxd).astype(np.int64)
        cols = ((lons - lon0) / pxd).astype(np.int64)
        rv = (rows >= 0) & (rows < arr.shape[0]); cv = (cols >= 0) & (cols < arr.shape[1])
        rr = np.clip(rows, 0, arr.shape[0] - 1); cc = np.clip(cols, 0, arr.shape[1] - 1)
        sub = arr[rr[:, None], cc[None, :]]
        m = rv[:, None] & cv[None, :]
        out[m] = sub[m]
    Image.fromarray(out, "L").save(ASSETS / "landcover.png")
    vals, cnts = np.unique(out, return_counts=True)
    names = {0: "нет", 10: "лес", 20: "кустарник", 30: "луг", 40: "пашня", 50: "застройка", 60: "голая", 70: "снег", 80: "вода", 90: "болото", 95: "мангры", 100: "мох"}
    print("классы:", ", ".join(f"{names.get(int(v), v)} {c / out.size * 100:.1f}%" for v, c in zip(vals, cnts)))
    print("Готово:", ASSETS / "landcover.png")


if __name__ == "__main__":
    sys.exit(main())
