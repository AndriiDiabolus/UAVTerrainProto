#!/usr/bin/env bash
# Экспорт билдов: ./tools/export.sh [win|linux|mac|all]
# Требует установленных export templates 4.6.1 (Godot: Editor → Manage Export Templates → Download,
# либо распаковать Godot_v4.6.1-stable_export_templates.tpz в
#   ~/Library/Application Support/Godot/export_templates/4.6.1.stable/  (macOS)
#   ~/.local/share/godot/export_templates/4.6.1.stable/                 (Linux)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Users/andriidiablo/Desktop/Sabbath_3D/Godot.app/Contents/MacOS/Godot}"
what="${1:-all}"
mkdir -p "$HERE/build/win" "$HERE/build/linux" "$HERE/build/mac"

# первый запуск в headless импортирует ресурсы (нужно для tex/*.jpg без .import)
"$GODOT" --headless --path "$HERE/godot" --import >/dev/null 2>&1 || true

exp() { echo "→ $1"; "$GODOT" --headless --path "$HERE/godot" --export-release "$1" "$2"; }
case "$what" in
  win)   exp "Windows Desktop" "$HERE/build/win/UAVTerrainProto.exe" ;;
  linux) exp "Linux" "$HERE/build/linux/UAVTerrainProto.x86_64" ;;
  mac)   exp "macOS" "$HERE/build/mac/UAVTerrainProto.zip" ;;
  all)   exp "Windows Desktop" "$HERE/build/win/UAVTerrainProto.exe"
         exp "Linux" "$HERE/build/linux/UAVTerrainProto.x86_64"
         exp "macOS" "$HERE/build/mac/UAVTerrainProto.zip" ;;
  *) echo "usage: $0 [win|linux|mac|all]"; exit 1 ;;
esac
cp "$HERE/ATTRIBUTION.md" "$HERE/build/" 2>/dev/null || true
echo "Готово: $HERE/build/"
