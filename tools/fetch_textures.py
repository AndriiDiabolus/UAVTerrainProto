#!/usr/bin/env python3
"""Качает CC0-текстуры с Poly Haven (albedo + normal, 1k jpg) в godot/assets/tex/.
Все ассеты Poly Haven — CC0 (public domain), коммерческое/оборонное использование ок."""
import json, urllib.request
from pathlib import Path

TEX = Path(__file__).resolve().parent.parent / "godot" / "assets" / "tex"
TEX.mkdir(parents=True, exist_ok=True)

# локальное имя -> slug Poly Haven
WANT = {
    "grass": "aerial_grass_rock",
    "dirt":  "aerial_mud_1",
    "rock":  "aerial_rocks_04",
    "roof":  "grey_roof_01",
    "wall":  "beige_wall_001",
    "asphalt": "asphalt_02",
    "gravel":  "gravel_road",
}

def get(u):
    req = urllib.request.Request(u, headers={"User-Agent": "terrain-proto/0.1"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

def dl(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        print("  кеш:", dest.name); return
    req = urllib.request.Request(url, headers={"User-Agent": "terrain-proto/0.1"})
    data = urllib.request.urlopen(req, timeout=120).read()
    dest.write_bytes(data)
    print("  ↓", dest.name, f"{len(data)//1024} KB")

def pick_url(node, res="1k"):
    """node = files['Diffuse'] или files['nor_gl']; вернуть jpg/png url нужного разрешения."""
    if res not in node:
        res = sorted(node.keys())[0]
    fmts = node[res]
    for f in ("jpg", "png"):
        if f in fmts:
            return fmts[f]["url"], f
    k = list(fmts.keys())[0]
    return fmts[k]["url"], k

for name, slug in WANT.items():
    print(f"{name} <- {slug}")
    files = get(f"https://api.polyhaven.com/files/{slug}")
    # albedo
    diff = files.get("Diffuse") or files.get("diffuse") or files.get("Color")
    url, ext = pick_url(diff)
    dl(url, TEX / f"{name}_diff.{ext}")
    # normal (OpenGL)
    nor = files.get("nor_gl") or files.get("Normal") or files.get("nor_dx")
    if nor:
        url, ext = pick_url(nor)
        dl(url, TEX / f"{name}_norm.{ext}")
    else:
        print("  (нормали нет)")

print("Готово. Источник: Poly Haven (CC0).")
