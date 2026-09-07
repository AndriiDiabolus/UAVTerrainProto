#!/usr/bin/env bash
# Запуск из исходников: ./run.sh [флаги после --, напр. --mode=acro --mission=1 --quality=low]
# Godot ищется: $GODOT → PATH → стандартные места.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
find_godot() {
  if [[ -n "${GODOT:-}" && -x "$GODOT" ]]; then echo "$GODOT"; return; fi
  if command -v godot >/dev/null 2>&1; then command -v godot; return; fi
  for c in "/Applications/Godot.app/Contents/MacOS/Godot" \
           "$HOME/Applications/Godot.app/Contents/MacOS/Godot" \
           "/Users/andriidiablo/Desktop/Sabbath_3D/Godot.app/Contents/MacOS/Godot"; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  echo "Godot 4.6 не найден: задайте GODOT=/путь/к/Godot" >&2; exit 1
}
G="$(find_godot)"
# самопочинка race-бага импорта: хвосты .ctex-XXXX прошлого запуска чиним ДО старта
setopt NULL_GLOB 2>/dev/null || shopt -s nullglob
for f in "$HERE"/godot/.godot/imported/*.ctex-*; do
  mv "$f" "${f%.ctex-*}.ctex" 2>/dev/null || true
done
exec "$G" --path "$HERE/godot" -- "$@"
