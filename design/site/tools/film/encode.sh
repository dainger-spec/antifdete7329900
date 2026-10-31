#!/bin/sh
# The film from its frames (capture.mjs) and its sound (sound.py): H.264 High, 1920 × 1080, 60 frames a
# second, BT.709 (what every player and site expects), AAC 256 kb/s, the index at the front so it starts at once.
#
#   sh tools/film/encode.sh ru        # → video/lumen-ru.mp4
set -e
cd "$(dirname "$0")/../.."
lang=${1:-ru}
frames=video/.cache/frames/$lang
n=$(ls "$frames" | grep -c '\.png$')
[ "$n" -eq 1800 ] || { echo "encode: $frames has $n frames of 1800 — film them first (capture.mjs $lang)"; exit 1; }
ffmpeg -y -v error -stats -framerate 60 -i "$frames/%04d.png" -i video/.cache/sound.wav -map 0:v -map 1:a \
  -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -c:v libx264 -preset slow -crf 16 -tune film -profile:v high -level 4.2 -g 120 -bf 3 \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart -shortest "video/lumen-$lang.mp4"
ls -l "video/lumen-$lang.mp4"
