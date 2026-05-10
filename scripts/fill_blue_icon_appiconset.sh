#!/bin/bash
# Resize master PNG to every BlueIcon.appiconset raster (macOS CI / local).
set -euo pipefail
MASTER="${1:?master png}"
SET_DIR="${2:?path to BlueIcon.appiconset}"
if ! command -v sips >/dev/null; then
  echo "sips not found (need macOS)" >&2
  exit 1
fi
shopt -s nullglob
for png in "$SET_DIR"/Icon*.png; do
  base=$(basename "$png" .png)
  if [[ "$base" =~ @([0-9]+)x([0-9]+) ]]; then
    W="${BASH_REMATCH[1]}"
    H="${BASH_REMATCH[2]}"
    sips -z "$H" "$W" "$MASTER" --out "$png" >/dev/null
    echo "  $base -> ${W}x${H}"
  fi
done
echo "BlueIcon.appiconset filled from $MASTER"
