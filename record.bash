#!/usr/bin/env bash
set -euo pipefail

CAST_FILE="record_result.cast"
GIF_FILE="record_result.gif"
MP4_FILE="record_result.mp4"

for bin in asciinema agg ffmpeg; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found in PATH" >&2
    exit 1
  fi
done

rm -f "$CAST_FILE" "$GIF_FILE" "$MP4_FILE"

echo ">>> [1/3] recording 'make all' via asciinema"
asciinema rec --idle-time-limit=2 -c "make all" "$CAST_FILE"

echo ">>> [2/3] converting cast -> gif"
agg "$CAST_FILE" "$GIF_FILE"

echo ">>> [3/3] converting gif -> mp4"
ffmpeg -y -i "$GIF_FILE" \
  -movflags faststart \
  -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  "$MP4_FILE"

rm -f "$CAST_FILE" "$GIF_FILE"

echo ">>> done: $(pwd)/$MP4_FILE"
