#!/usr/bin/env bash
# Regenerates Support/AppIcon.icns (and Support/AppIcon.png) from scripts/make-icon.swift.
# Usage: scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$TMP/icon_1024.png" >/dev/null
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Support/AppIcon.icns
cp "$TMP/icon_1024.png" Support/AppIcon.png
echo "Wrote Support/AppIcon.icns"
