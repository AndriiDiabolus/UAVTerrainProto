#!/usr/bin/env bash
# Headless-импорт ассетов Godot + починка race-бага:編 headless --import иногда выходит,
# не переименовав готовые .ctex-XXXXXX во финальные .ctex (текстура при этом записана целиком).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${GODOT:-/Users/andriidiablo/Desktop/Sabbath_3D/Godot.app/Contents/MacOS/Godot}"
"$G" --headless --path "$HERE/godot" --import >/dev/null 2>&1 || true
shopt -s nullglob
for f in "$HERE"/godot/.godot/imported/*.ctex-*; do
  mv "$f" "${f%.ctex-*}.ctex"
  echo "починен: $(basename "${f%.ctex-*}").ctex"
done
echo "импорт готов"
