#!/usr/bin/env bash
# Архивы для раздачи бета-тестерам: ./tools/package.sh [версія]
# Бере готові білди з build/win і build/mac (спершу ./tools/export.sh all) → build/dist/*.zip
# У кожному архіві: гра + README.txt (інструкція запуску) + ATTRIBUTION.md (вимога ліцензій даних).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-beta}"
cd "$HERE/build"
rm -rf dist && mkdir -p dist
pack() {   # $1 — назва теки в архіві, $2 — ім'я zip
  cp "$HERE/ATTRIBUTION.md" "dist/$1/"
  cp "$HERE/tools/dist/README.txt" "dist/$1/README.txt"
  # ditto: зберігає біт виконуваності й підпис .app; без __MACOSX і resource forks
  (cd dist && ditto -c -k --norsrc --noextattr --keepParent "$1" "$2" && rm -rf "$1")
  echo "→ build/dist/$2 ($(( $(stat -f %z "dist/$2") / 1048576 )) МБ)"
}
if [ -f win/UAVTerrainProto.exe ]; then
  mkdir -p "dist/UAV Terrain Beta (Windows)"
  cp win/UAVTerrainProto.exe "dist/UAV Terrain Beta (Windows)/"
  pack "UAV Terrain Beta (Windows)" "UAVTerrain-$VER-windows.zip"
fi
if [ -f mac/UAVTerrainProto.zip ]; then
  mkdir -p "dist/UAV Terrain Beta (macOS)"
  ditto -x -k mac/UAVTerrainProto.zip "dist/UAV Terrain Beta (macOS)"
  pack "UAV Terrain Beta (macOS)" "UAVTerrain-$VER-macos.zip"
fi
