#!/bin/sh
# The film v3 from its frames (capture.mjs → video/.cache/frames3/<lang>/) and a sound: H.264 High, 1920 × 1080,
# 60 frames a second, BT.709 (what every player and site expects), AAC 256 kb/s, the index at the front so it
# starts at once.
#
#   sh tools/film3/encode.sh ru --audio FILE [--out FILE]   # → video/lumen-v3-ru.mp4
# Without --audio the mp4 has no sound (and says so).
set -e
cd "$(dirname "$0")/../.."
lang=${1:-ru}
shift || true
audio=""
out=video/lumen-v3-$lang.mp4
while [ $# -gt 0 ]; do
  case "$1" in
    --audio) audio="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "encode: unknown option $1"; exit 2 ;;
  esac
done
frames=video/.cache/frames3/$lang
n=$(ls "$frames" 2>/dev/null | grep -c '^[0-9]\{4\}\.png$' || true)
[ "$n" -eq 1800 ] || { echo "encode: $frames has $n frames of 1800 — film them first (capture.mjs $lang)"; exit 1; }
venc="-c:v libx264 -preset slow -crf 16 -tune film -profile:v high -level 4.2 -pix_fmt yuv420p -g 120 -bf 3"
tags="-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv"
scale="scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"
if [ -n "$audio" ]; then
  ffmpeg -y -v error -stats -framerate 60 -i "$frames/%04d.png" -i "$audio" -map 0:v -map 1:a -vf "$scale" $venc $tags \
    -c:a aac -b:a 256k -ar 48000 -movflags +faststart -t 30 "$out"
else
  echo "encode: no sound given (--audio FILE) — the mp4 is picture only"
  ffmpeg -y -v error -stats -framerate 60 -i "$frames/%04d.png" -vf "$scale" $venc $tags -movflags +faststart -t 30 "$out"
fi
ls -l "$out"
