#!/bin/bash
# Pack the approved Gallery at Sunset master into the macOS icon family.
# assets/icon-1024.png is the canonical RGBA source; do not regenerate it
# from the retired parametric icon.
set -euo pipefail
cd "$(dirname "$0")/.."

test -f assets/icon-1024.png

ICONSET=$(mktemp -d)/artbip.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o assets/artbip.icns
rm -rf "$(dirname "$ICONSET")"
echo "packed assets/icon-1024.png into assets/artbip.icns"
