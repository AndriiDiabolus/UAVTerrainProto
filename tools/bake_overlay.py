#!/usr/bin/env python3
"""Запекает OSM-дороги в albedo.jpg (чёткие линии поверх спутника) и строит
маску землепользования mask.png (2048², L8): 0 прочее, 1 лес, 2 дорога, 3 застройка.
Оригинал спутника сохраняется в albedo_clean.jpg (идемпотентно)."""
import os
import json, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ASSETS = Path(os.environ["UAV_ASSETS"]) if os.environ.get("UAV_ASSETS") else Path(__file__).resolve().parent.parent / "godot" / "assets"
META = json.loads((ASSETS / "meta.json").read_text())
SIZE = META["size_m"]

clean_p = ASSETS / "albedo_clean.jpg"
if not clean_p.exists():
    (ASSETS / "albedo.jpg").rename(clean_p)
alb = Image.open(clean_p).convert("RGB")
W = alb.width                      # 8192
MW = 2048                          # маска
mask = Image.new("L", (MW, MW), 0)

def to_px(pt, w):
    return ((pt[0] / SIZE + 0.5) * w, (pt[1] / SIZE + 0.5) * w)

# --- классификация леса (по чистому спутнику, downsample до 2048) ---
print("Классифицирую лес...")
small = alb.resize((MW, MW), Image.LANCZOS)
md = mask.load(); sd = small.load()
for y in range(MW):
    for x in range(MW):
        r, g, b = sd[x, y]
        if g >= r + 6 and g >= b + 6 and (r + g + b) <= 68:
            md[x, y] = 1

# --- реки (до дорог: мосты сверху) ---
water_p = ASSETS / "water.json"
if water_p.exists():
    print("Рисую реки...")
    wdraw = ImageDraw.Draw(alb)
    ways = json.loads(water_p.read_text())["w"]
    for wobj in ways:
        pts = [to_px(p, W) for p in wobj["p"]]
        if wobj["c"] == "river":
            wdraw.line(pts, fill=(58, 74, 78), width=5, joint="curve")
        else:
            wdraw.line(pts, fill=(52, 66, 66), width=1, joint="curve")

# --- дороги ---
print("Рисую дороги...")
roads = json.loads((ASSETS / "roads.json").read_text())["roads"]
STYLE = {  # класс: (ширина заливки px@8192, цвет)
    "track":        (1, (106, 90, 68)),
    "service":      (1, (118, 116, 112)),
    "residential":  (1, (128, 126, 122)),
    "unclassified": (1, (126, 124, 120)),
    "tertiary":     (2, (133, 131, 126)),
    "secondary":    (2, (138, 135, 129)),
    "primary":      (3, (144, 140, 131)),
    "trunk":        (3, (148, 143, 133)),
    "motorway":     (3, (150, 145, 135)),
}
ORDER = ["track", "service", "unclassified", "residential", "tertiary",
         "secondary", "primary", "trunk", "motorway"]
overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
mdraw = ImageDraw.Draw(mask)
CASING = (78, 74, 68)
for cls in ORDER:
    wf, col = STYLE[cls]
    for r in roads:
        if r["c"] != cls:
            continue
        pts = [to_px(p, W) for p in r["p"]]
        if wf >= 3:
            draw.line(pts, fill=CASING + (255,), width=wf + 1, joint="curve")
for cls in ORDER:
    wf, col = STYLE[cls]
    wm = max(2, round(wf * MW / W) + 1)
    for r in roads:
        if r["c"] != cls:
            continue
        pts = [to_px(p, W) for p in r["p"]]
        draw.line(pts, fill=col + (255,), width=wf, joint="curve")
        mpts = [to_px(p, MW) for p in r["p"]]
        mdraw.line(mpts, fill=2, width=wm, joint="curve")

# --- застройка в маске ---
print("Отмечаю застройку...")
blds = json.loads((ASSETS / "buildings.json").read_text())["b"]
for cx, cz, w, d, ang, h in blds:
    x, y = to_px((cx, cz), MW)
    rad = max(1.5, (max(w, d) / 2 + 12) * MW / SIZE)
    mdraw.ellipse([x - rad, y - rad, x + rad, y + rad], fill=3)

overlay = overlay.filter(ImageFilter.GaussianBlur(0.8))
alb = Image.alpha_composite(alb.convert("RGBA"), overlay).convert("RGB")
alb.save(ASSETS / "albedo.jpg", quality=95)
mask.save(ASSETS / "mask.png")
print(f"Готово: {len(roads)} дорог запечено, {len(blds)} зданий в маске.")
