#!/bin/sh
# The promo film v2 from its frames (post.py → video/.cache/frames/<lang>/, 1920 × 1080, 8-bit) and a sound:
#   H.264 High, yuv420p, BT.709 tagged, limited range, CRF 12 with -tune grain, aq-mode 3, deblock −2,−2;
#   AAC 256 kb/s at 48 kHz; the index at the front. At least 15 Mb/s (checked after).
#   With --master: ProRes 422 HQ 10-bit (prores_ks profile 3, yuv422p10le) from post.py --master's 16-bit frames.
#   Then QA: the frames at 7.0, 11.0, 18.75 and 28.5 s decoded from the mp4 and brightened 10× (banding, blocking)
#   into video/.cache/qa/<lang>/.
#
#   sh tools/film/encode.sh ru [--audio FILE] [--master]   # → video/lumen-v2-ru.mp4 (v1's lumen-ru.mp4 is kept)
# Without --audio, video/.cache/foley.wav is used if it exists; otherwise the mp4 has no sound (and says so).
set -e
cd "$(dirname "$0")/../.."
lang=${1:-ru}
shift || true
audio=""
master=0
while [ $# -gt 0 ]; do
  case "$1" in
    --audio) audio="$2"; shift 2 ;;
    --master) master=1; shift ;;
    *) echo "encode: unknown option $1"; exit 2 ;;
  esac
done
[ -z "$audio" ] && [ -f video/.cache/foley.wav ] && audio=video/.cache/foley.wav
frames=video/.cache/frames/$lang
n=$(ls "$frames" 2>/dev/null | grep -c '^[0-9]\{4\}\.png$' || true)
[ "$n" -eq 1800 ] || { echo "encode: $frames has $n frames of 1800 — capture.mjs $lang, then post.py $lang"; exit 1; }
# every frame posted from this film's own capture (the folder also held v1's frames): newer than its record
for j in video/.cache/dom/$lang/[0-9][0-9][0-9][0-9].json; do
  p="$frames/$(basename "$j" .json).png"
  [ "$p" -nt "$j" ] || { echo "encode: $p is older than its capture $j — post.py $lang"; exit 1; }
done
k=$(ls video/.cache/dom/$lang 2>/dev/null | grep -c '^[0-9]\{4\}\.json$' || true)
[ "$k" -eq 1800 ] || { echo "encode: video/.cache/dom/$lang has $k frame records of 1800 — capture.mjs $lang"; exit 1; }
out=video/lumen-v2-$lang.mp4
venc="-c:v libx264 -preset slow -crf 12 -tune grain -x264-params aq-mode=3:deblock=-2,-2 -profile:v high -level 4.2 -pix_fmt yuv420p -g 120 -bf 3"
tags="-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv"
scale="scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"
if [ -n "$audio" ]; then
  ffmpeg -y -v error -stats -framerate 60 -i "$frames/%04d.png" -i "$audio" -map 0:v -map 1:a -vf "$scale" $venc $tags \
    -c:a aac -b:a 256k -ar 48000 -movflags +faststart -t 30 "$out"
else
  echo "encode: no sound given (--audio FILE) and no video/.cache/foley.wav — the mp4 is picture only"
  ffmpeg -y -v error -stats -framerate 60 -i "$frames/%04d.png" -vf "$scale" $venc $tags -movflags +faststart -t 30 "$out"
fi
rate=$(ffprobe -v error -select_streams v:0 -show_entries format=bit_rate -of default=nw=1:nk=1 "$out")
echo "$out: $(ls -l "$out" | awk '{print $5}') bytes, $((rate / 1000)) kb/s overall"
[ "$rate" -ge 15000000 ] || echo "encode: WARNING — under 15 Mb/s"

if [ "$master" -eq 1 ]; then
  m=video/.cache/master/$lang
  k=$(ls "$m" 2>/dev/null | grep -c '^[0-9]\{4\}\.png$' || true)
  [ "$k" -eq 1800 ] || { echo "encode: $m has $k 16-bit frames of 1800 — post.py $lang --master"; exit 1; }
  ffmpeg -y -v error -stats -framerate 60 -i "$m/%04d.png" -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv422p10le" \
    -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 $tags "video/.cache/lumen-v2-$lang-master.mov"
  ls -l "video/.cache/lumen-v2-$lang-master.mov"
fi

# QA: decoded frames, brightened 10×
qa=video/.cache/qa/$lang
mkdir -p "$qa"
for t in 7.0 11.0 18.75 28.5; do
  ffmpeg -y -v error -ss "$t" -i "$out" -frames:v 1 -vf "scale=in_range=tv:out_range=pc,format=rgb24,lutrgb=r='min(val*10,255)':g='min(val*10,255)':b='min(val*10,255)'" "$qa/x10-$t.png"
done
echo "QA frames (×10): $qa/x10-{7.0,11.0,18.75,28.5}.png — look for banding and blocking"
