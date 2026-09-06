#!/usr/bin/env bash
# Headless-импорт ассетов Godot + починка race-бага: headless --import иногда выходит,
# не переименовав готовые .ctex-XXXXXX во финальные .ctex (текстура записана целиком).
# Цикл: импорт → починка → повтор, пока не выйдет чисто (до 4 проходов).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${GODOT:-/Users/andriidiablo/Desktop/Sabbath_3D/Godot.app/Contents/MacOS/Godot}"
shopt -s nullglob
for pass in 1 2 3 4; do
  "$G" --headless --path "$HERE/godot" --import >/dev/null 2>&1 || true
  fixed=0
  for f in "$HERE"/godot/.godot/imported/*.ctex-*; do
    mv "$f" "${f%.ctex-*}.ctex"
    echo "починен (проход $pass): $(basename "${f%.ctex-*}").ctex"
    fixed=1
  done
  [ "$fixed" = "0" ] && break
done
echo "импорт готов"
