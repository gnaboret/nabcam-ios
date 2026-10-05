#!/bin/bash
set -euo pipefail
# Build-time asset normalization; keep the original artwork unchanged in Git.
cd "$(dirname "$0")/.."
source_icon="Artwork/icon-source.png"
target_icon="NabcamIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if [[ ! -f "$target_icon" || "$source_icon" -nt "$target_icon" ]]; then
  /usr/bin/sips --resampleHeightWidth 1024 1024 "$source_icon" --out "$target_icon" >/dev/null
fi
