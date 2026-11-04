#!/bin/bash
# The disk image's window as a person sees it, and whether it shows its picture (the owner, 2 and
# 3 November: the layout is checked by a picture of the window, and 0.1.1's window had its icons and
# its size but no picture while make_dmg.sh said it was laid out). The image mounted where Finder
# sees it, its window opened by Finder, that part of the screen captured and compared, point by
# point, with the picture the image carries (scripts/dmg_background_check.py).
#
#   scripts/dmg_window_shot.sh path/to/Lumen.dmg folder [--both] [--expect shown|not-shown]
#
# Writes, for each capture, folder/dmg-window-<appearance>.png, the window's geometry beside it
# (.json) and the verdict; once, folder/layout-facts.txt: what the volume holds and what its
# .DS_Store says (scripts/dmg_facts.py), and what Finder answers when asked for the window's
# background picture. folder/picture.png is the image's own picture (.background/background.tiff, its
# first page, or .background/background.png), as the reference.
#   --both                 the light appearance and then the dark one (CI: Finder writes the icons'
#                          names black in one and white in the other); without it, this Mac's
#                          appearance only, which is never changed.
#   --expect not-shown     the control: an image made without its picture must not pass.
# Exit 0 when every capture is as expected, 1 when one is not, 2 when nothing could be captured. If
# this terminal may not record the screen (System Settings › Privacy & Security › Screen & System
# Audio Recording), a capture holds no window and its verdict says NOT SHOWN: allow it, run again.
set -uo pipefail
DMG="${1:?the disk image}"
OUT="${2:?a folder for the pictures}"
shift 2
BOTH=0
EXPECT=shown
while (( $# )); do
  case "$1" in
    --both) BOTH=1 ;;
    --expect) EXPECT="${2:?shown or not-shown}"; shift ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$EXPECT" == shown || "$EXPECT" == not-shown ]] || { echo "error: --expect shown or not-shown" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
FACTS="$OUT/layout-facts.txt"
: > "$FACTS"
status=0
captured=0

shot() {
  local appearance="$1" mount disk bounds answer
  mount="$(hdiutil attach "$DMG" -readonly -noverify | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  [[ -n "$mount" ]] || { echo "$appearance: the image did not mount"; return 2; }
  disk="$(basename "$mount")"
  if [[ ! -s "$FACTS" ]]; then
    python3 -I "$HERE/dmg_facts.py" "$mount" > "$FACTS" 2>&1
    answer="$(osascript -e "tell application \"Finder\" to get background picture of icon view options of container window of disk \"$disk\"" 2>&1)"
    echo "layout facts: Finder, asked for the window's background picture, answers: ${answer:-nothing} (no fact: on macOS 27 it fails with -10000 even when the picture is set and kept, CI run 672)" >> "$FACTS"
    cat "$FACTS"
    rm -f "$OUT/picture.png"
    local picture
    for picture in "$mount/.background/background.tiff" "$mount/.background/background.png"; do
      [[ -f "$picture" ]] || continue
      sips -s format png "$picture" --out "$OUT/picture.png" >/dev/null 2>&1 \
        || echo "the image's picture could not be read by sips"
      break
    done
  fi
  open "$mount"
  sleep 4
  # Finder's window, left, top, right, bottom in points from the screen's top left: its frame,
  # the title bar included; the capture takes a margin around it.
  bounds="$(osascript -e 'tell application "Finder" to get bounds of front window' 2>/dev/null | tr -d ' ')"
  echo "$appearance: Finder's window $bounds"
  if [[ "$bounds" =~ ^(-?[0-9]+),(-?[0-9]+),(-?[0-9]+),(-?[0-9]+)$ ]]; then
    local x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}" right="${BASH_REMATCH[3]}" bottom="${BASH_REMATCH[4]}"
    local cx=$((x - 8)) cy=$((y - 40)) cw=$((right - x + 16)) ch=$((bottom - y + 48))
    screencapture -x -R "$cx,$cy,$cw,$ch" "$OUT/dmg-window-$appearance.png"
    printf '{"appearance": "%s", "bounds": [%d, %d, %d, %d], "capture": [%d, %d, %d, %d]}\n' \
      "$appearance" "$x" "$y" "$right" "$bottom" "$cx" "$cy" "$cw" "$ch" > "$OUT/dmg-window-$appearance.json"
    captured=$((captured + 1))
  else
    screencapture -x "$OUT/dmg-window-$appearance.png"
    echo "$appearance: Finder gave no window's bounds: the whole screen captured, nothing compared"
  fi
  osascript -e 'tell application "Finder" to close front window' >/dev/null 2>&1
  hdiutil detach "$mount" -force -quiet
  [[ -f "$OUT/dmg-window-$appearance.json" ]] || return 2
  if [[ ! -f "$OUT/picture.png" ]]; then
    echo "window picture ($appearance): NOT SHOWN — the image carries no picture (.background)"
    [[ "$EXPECT" == not-shown ]] && return 0 || return 1
  fi
  python3 -I "$HERE/dmg_background_check.py" --shot "$OUT/dmg-window-$appearance.png" \
    --geometry "$OUT/dmg-window-$appearance.json" --picture "$OUT/picture.png"
  local verdict=$?
  if [[ "$EXPECT" == shown ]]; then
    return $verdict
  fi
  case $verdict in
    0) echo "window picture ($appearance): the control PASSED the check — a check that cannot fail shows nothing"; return 1 ;;
    1) echo "window picture ($appearance): the control fails the check, as it must"; return 0 ;;
    *) return 2 ;;
  esac
}

dark() { osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null 2>&1; }
note() { (( $1 > status )) && status=$1; }
if (( BOTH )); then
  dark false; sleep 2
  shot light; note $?
  if dark true; then
    sleep 3
    shot dark; note $?
    dark false
  else
    echo "the dark appearance could not be set: the window was captured in the light one only"
    note 1
  fi
else
  # Read, not asked of System Events: on the release's Mac that would be one more question to allow.
  shot "$([[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" == Dark ]] && echo dark || echo light)"; note $?
fi
(( captured > 0 )) || { echo "no window was captured"; exit 2; }
ls -la "$OUT"
exit $status
