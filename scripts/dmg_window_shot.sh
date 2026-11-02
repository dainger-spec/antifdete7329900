#!/bin/bash
# The disk image's window as a person sees it (the owner, 2 November: the layout is checked by a
# picture of the window, not of its parts): the image mounted where Finder sees it, its window
# opened by Finder, and that part of the screen captured — in this Mac's light and dark appearance,
# since Finder writes the icons' names black in the one and white in the other.
#
#   scripts/dmg_window_shot.sh path/to/Lumen.dmg folder
#
# Writes folder/dmg-window-light.png and folder/dmg-window-dark.png, and says whether the window
# was laid out (a .DS_Store in the image) or Finder's own.
set -uo pipefail
DMG="${1:?the disk image}"
OUT="${2:?a folder for the pictures}"
mkdir -p "$OUT"

shot() {
  local appearance="$1" mount bounds
  mount="$(hdiutil attach "$DMG" -readonly -noverify | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  [[ -n "$mount" ]] || { echo "the image did not mount"; return 1; }
  [[ -f "$mount/.DS_Store" ]] && echo "$appearance: the window is laid out (.DS_Store)" || echo "$appearance: Finder's own window (no .DS_Store)"
  open "$mount"
  sleep 4
  # Finder's window, top left to bottom right, in points from the screen's top left; the title bar
  # is above the content's bounds.
  bounds="$(osascript -e 'tell application "Finder" to get bounds of front window' 2>/dev/null | tr -d ' ')"
  echo "$appearance: Finder's window $bounds"
  if [[ "$bounds" =~ ^(-?[0-9]+),(-?[0-9]+),(-?[0-9]+),(-?[0-9]+)$ ]]; then
    local x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}" right="${BASH_REMATCH[3]}" bottom="${BASH_REMATCH[4]}"
    screencapture -x -R"$((x - 8)),$((y - 40)),$((right - x + 16)),$((bottom - y + 48))" "$OUT/dmg-window-$appearance.png"
  else
    screencapture -x "$OUT/dmg-window-$appearance.png"
  fi
  osascript -e 'tell application "Finder" to close front window' >/dev/null 2>&1
  hdiutil detach "$mount" -force -quiet
}

dark() { osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null 2>&1; }
status=0
dark false; sleep 2
shot light || status=1
if dark true; then
  sleep 3
  shot dark || status=1
  dark false
else
  echo "the dark appearance could not be set: the window was captured in the light one only"
  status=1
fi
ls -la "$OUT"
exit $status
