#!/usr/bin/env python3
"""Ветер для полигона «Сетевой заслон»: почасовой ERA5 (через Open-Meteo, без ключа)
на высоте 100 м — середина полотна 12…190 м — по областным центрам Украины.

Строит гистограммы скорости (шаг 1 м/с) в разрезах: всё время, ночь (21–06 местного —
время большинства налётов), день, зима (дек–фев), лето (июн–авг).
Результат: godot/assets/netdef/wind_hist.json (его читает --netwindrose).
Сырые ответы кешируются в tools/wind_cache/ (в git не попадают).

    python3 tools/fetch_wind.py [--years 2023-2025]
"""
import json, os, sys, time, urllib.request, argparse

REGIONS = [
    ("odesa", "Одеса", 46.48, 30.72), ("mykolaiv", "Миколаїв", 46.97, 31.99),
    ("kherson", "Херсон", 46.64, 32.61), ("zaporizhzhia", "Запоріжжя", 47.84, 35.14),
    ("dnipro", "Дніпро", 48.46, 35.05), ("kryvyi_rih", "Кривий Ріг", 47.91, 33.39),
    ("kharkiv", "Харків", 49.99, 36.23), ("poltava", "Полтава", 49.59, 34.55),
    ("sumy", "Суми", 50.91, 34.80), ("chernihiv", "Чернігів", 51.49, 31.29),
    ("kyiv", "Київ", 50.45, 30.52), ("vinnytsia", "Вінниця", 49.23, 28.47),
    ("lviv", "Львів", 49.84, 24.03),
]
NB = 31  # бины 0..30 м/с, последний — «30 и больше»
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "wind_cache")
OUT = os.path.join(HERE, "..", "godot", "assets", "netdef", "wind_hist.json")


def fetch(lat, lon, y0, y1):
    url = ("https://archive-api.open-meteo.com/v1/archive?latitude=%.2f&longitude=%.2f"
           "&start_date=%d-01-01&end_date=%d-12-31&hourly=wind_speed_100m,wind_speed_10m"
           "&wind_speed_unit=ms&timezone=Europe%%2FKyiv" % (lat, lon, y0, y1))
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=90) as r:
                return json.load(r)
        except Exception as e:  # сеть/лимит — повтор с паузой
            print("  повтор %d: %s" % (attempt + 1, e))
            time.sleep(5 * (attempt + 1))
    raise SystemExit("не удалось скачать %s" % url)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--years", default="2023-2025")
    a = ap.parse_args()
    y0, y1 = [int(x) for x in a.years.split("-")]
    os.makedirs(CACHE, exist_ok=True)
    out = {"source": "ERA5 hourly via Open-Meteo archive API (CC BY 4.0), wind_speed_100m",
           "years": [y0, y1], "bin_ms": 1, "slices": ["all", "night", "day", "winter", "summer"],
           "regions": []}
    for key, name, lat, lon in REGIONS:
        cp = os.path.join(CACHE, "%s_%d_%d.json" % (key, y0, y1))
        if os.path.exists(cp):
            data = json.load(open(cp))
        else:
            print("качаю %s…" % name)
            data = fetch(lat, lon, y0, y1)
            json.dump(data, open(cp, "w"))
            time.sleep(1.5)
        t = data["hourly"]["time"]; w = data["hourly"]["wind_speed_100m"]
        w10 = data["hourly"]["wind_speed_10m"]
        h = {s: [0] * NB for s in out["slices"]}
        n_ok = 0; s100 = 0.0; s10 = 0.0
        for ti, wi, wj in zip(t, w, w10):
            if wi is None:
                continue
            n_ok += 1; s100 += wi; s10 += (wj or 0.0)
            b = min(int(wi), NB - 1)
            hour = int(ti[11:13]); month = int(ti[5:7])
            h["all"][b] += 1
            h["night" if (hour >= 21 or hour < 6) else "day"][b] += 1
            if month in (12, 1, 2): h["winter"][b] += 1
            if month in (6, 7, 8): h["summer"][b] += 1
        out["regions"].append({"id": key, "name": name, "lat": lat, "lon": lon, "hours": n_ok,
                               "mean100": round(s100 / max(n_ok, 1), 2),
                               "mean10": round(s10 / max(n_ok, 1), 2), "hist": h})
        print("  %-11s часов %d · средний ветер 100 м %.1f м/с (10 м %.1f)"
              % (name, n_ok, s100 / max(n_ok, 1), s10 / max(n_ok, 1)))
    json.dump(out, open(OUT, "w"), ensure_ascii=False, separators=(",", ":"))
    print("→", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
