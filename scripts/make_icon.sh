#!/bin/bash
# Regenerate the app icon: renders assets/icon-1024.png from the parametric
# SwiftUI source (make_icon.swift), then packs assets/artbip.icns.
# Design notes: 1024 canvas, 824pt continuous-corner squircle (Apple template);
# metaphor = a spotlit gold-framed painting on a gallery wall; light-to-dark
# vertical gradient per Liquid Glass guidance. macOS 26 layered `.icon`
# conversion (Icon Composer / actool) still pending — needs full Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make_icon.swift assets/icon-1024.png

ICONSET=$(mktemp -d)/artbip.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o assets/artbip.icns
rm -rf "$(dirname "$ICONSET")"
echo "wrote assets/icon-1024.png and assets/artbip.icns"
