#!/usr/bin/env python3
"""Процедурные фасадные текстуры (окна/двери/ставни) для типов застройки:
   cottage — сельская хата, house — 2-этажный, barn — сарай, block — ПГТ/многоквартирный.
Текстура = одна стена (низ = земля/дверь, верх = карниз); мапится по UV коробки.
Сохраняет в godot/assets/tex/facades/*.png (свои, без лицензионных ограничений)."""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "godot" / "assets" / "tex" / "facades"
OUT.mkdir(parents=True, exist_ok=True)
S = 512

GLASS = (58, 74, 92)
GLASS_LIT = (150, 150, 110)
FRAME = (236, 232, 224)
SHUT = [(120, 78, 52), (90, 104, 96), (70, 92, 120), (140, 120, 70)]
DOOR = [(96, 64, 40), (70, 78, 92), (110, 96, 70)]


def window(d, x, y, w, h, shutters=True, lit=False, i=0):
    d.rectangle([x - 2, y - 2, x + w + 2, y + h + 2], fill=FRAME)          # рама
    d.rectangle([x, y, x + w, y + h], fill=GLASS_LIT if lit else GLASS)     # стекло
    cx, cy = x + w // 2, y + h // 2
    d.line([cx, y, cx, y + h], fill=FRAME, width=3)                         # переплёт
    d.line([x, cy, x + w, cy], fill=FRAME, width=3)
    d.rectangle([x - 3, y + h + 2, x + w + 3, y + h + 6], fill=(200, 196, 188))  # подоконник
    if shutters:
        c = SHUT[i % len(SHUT)]
        d.rectangle([x - 2 - w // 3, y - 2, x - 2, y + h + 2], fill=c)      # левая ставня
        d.rectangle([x + w + 2, y - 2, x + w + 2 + w // 3, y + h + 2], fill=c)


def door(d, x, y, w, h, i=0):
    c = DOOR[i % len(DOOR)]
    d.rectangle([x - 3, y - 3, x + w + 3, y + h], fill=(210, 205, 196))     # наличник
    d.rectangle([x, y, x + w, y + h], fill=c)
    d.line([x + w // 2, y, x + w // 2, y + h], fill=(40, 30, 20), width=2)  # створки
    d.ellipse([x + w - 12, y + h // 2 - 3, x + w - 6, y + h // 2 + 3], fill=(220, 200, 120))


def base(color):
    img = Image.new("RGB", (S, S), color)
    return img, ImageDraw.Draw(img)


def cottage():
    img, d = base((214, 202, 180))
    # низ = земля; дверь по центру, 2 окна по бокам, окно на чердаке
    door(d, 226, 330, 60, 150, i=1)
    window(d, 70, 350, 90, 110, i=0)
    window(d, 352, 350, 90, 110, i=0)
    window(d, 210, 150, 92, 96, i=2)     # чердачное
    img.save(OUT / "cottage.png")


def house():   # 2 этажа
    img, d = base((206, 198, 186))
    door(d, 60, 350, 58, 130, i=1)
    for x in [180, 300, 420]:
        window(d, x, 360, 76, 100, i=1)   # 1-й этаж
    for x in [60, 180, 300, 420]:
        window(d, x, 170, 76, 104, lit=(x == 300), i=3)  # 2-й этаж
    img.save(OUT / "house.png")


def barn():
    img, d = base((132, 104, 74))         # деревянные стены
    dd = ImageDraw.Draw(img)
    for y in range(0, S, 26):             # доски
        dd.line([0, y, S, y], fill=(112, 88, 62), width=2)
    door(d, 200, 300, 112, 180, i=0)      # большие ворота
    window(d, 60, 340, 70, 80, shutters=False, i=0)
    window(d, 380, 340, 70, 80, shutters=False, i=0)
    img.save(OUT / "barn.png")


def block():   # ПГТ, многоквартирный
    img, d = base((188, 184, 176))
    rows = 6
    cols = 5
    mx, my = 30, 24
    gw = (S - mx * (cols + 1)) // cols
    gh = (S - my * (rows + 1)) // rows
    import random
    random.seed(7)
    for r in range(rows):
        for c in range(cols):
            x = mx + c * (gw + mx)
            y = my + r * (gh + my)
            window(d, x, y, gw, gh, shutters=False, lit=(random.random() < 0.18))
    img.save(OUT / "block.png")


for f in (cottage, house, barn, block):
    f()
print("Фасады готовы:", ", ".join(p.name for p in OUT.glob("*.png")))
