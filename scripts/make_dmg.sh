#!/bin/bash
# The disk image the website offers (the owner, 1 and 2 November): Lumen and a link to
# Applications, its window laid out so that what to do is plain — drag the one onto the other.
# From a zip, people leave the app in Downloads, where macOS runs it translocated and an update
# cannot replace it; the image asks for the drag.
#
#   scripts/make_dmg.sh path/to/Lumen.app path/to/Lumen-1.2.3.dmg [--plain]
#
# The window's layout — the picture behind it (`Lumen --render-dmg-background`), its size, the
# icons' size and places — is Finder's to keep, in the image's .DS_Store, and only Finder writes it:
# this script asks Finder over AppleScript while a writable copy of the image is mounted. On the
# release's Mac macOS asks once whether the terminal the script runs in may control Finder
# ("“Terminal” wants access to control “Finder”…": Allow; System Settings › Privacy & Security ›
# Automation turns it on again later). Whatever goes wrong there — the picture, Finder, the question
# not answered within a minute — the image is made plain, the app and the link in Finder's own
# window, and the release goes on: the layout never stops one (the owner's order, 2 November).
# `--plain` makes it plain from the start.
#
# The app is copied as it is — signed, notarized and stapled before this — into a compressed,
# read-only image (UDZO), and read back from the image as it will be downloaded. Signing,
# notarizing and stapling the image itself is release.sh's. Nothing is installed for this:
# hdiutil, osascript, tiffutil, xattr, ditto and codesign come with macOS.
set -euo pipefail

APP="${1:?the app bundle}"
DMG="${2:?the disk image to write}"
PLAIN=0
[[ "${3:-}" == "--plain" ]] && PLAIN=1
[[ -d "$APP" && -x "$APP/Contents/MacOS/Lumen" ]] || { echo "error: $APP is not Lumen.app" >&2; exit 1; }
[[ "$DMG" == *.dmg ]] || { echo "error: $DMG does not end in .dmg" >&2; exit 1; }

VOLUME="Lumen"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-dmg.XXXXXX")"
MOUNT=""
CHECK=""
cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force -quiet || true; fi
  if [[ -n "$CHECK" && -d "$CHECK" ]]; then hdiutil detach "$CHECK" -force -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. What the image holds: the app and the link.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lumen.app"
ln -s /Applications "$STAGE/Applications"

# 2. The window laid out by Finder, in a writable copy; any failure leaves `why` said and the
#    image plain.
why=""
laid_out() {
  # The window's picture (one file for both kinds of screen: Finder takes the 2x page on a Retina
  # display) and the volume's icon.
  mkdir -p "$WORK/decorated"
  ditto "$STAGE" "$WORK/decorated"
  mkdir -p "$WORK/decorated/.background"
  "$APP/Contents/MacOS/Lumen" --render-dmg-background "$WORK/background" >/dev/null || { why="the picture was not drawn"; return 1; }
  tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
    -out "$WORK/decorated/.background/background.tiff" >/dev/null || { why="the picture was not put together"; return 1; }
  if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/decorated/.VolumeIcon.icns"; fi

  local size_mb=$(( $(du -sm "$WORK/decorated" | cut -f1) + 64 ))
  hdiutil create -quiet -volname "$VOLUME" -fs HFS+ -format UDRW -size "${size_mb}m" -srcfolder "$WORK/decorated" "$WORK/rw.dmg" \
    || { why="the writable image was not made"; return 1; }
  # Another volume named Lumen would put this one at "/Volumes/Lumen 1": the mount point is read.
  MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  [[ -n "$MOUNT" && -d "$MOUNT" ]] || { why="the writable image did not mount"; return 1; }
  local disk; disk="$(basename "$MOUNT")"
  # The volume's own icon: the Finder flag "has a custom icon" (0x0400) on the volume's root.
  if [[ -f "$MOUNT/.VolumeIcon.icns" ]]; then
    xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT" || true
  fi
  # The window, as Finder keeps it: 660 × 400 points of content, the icons' centres as
  # DiskImageBackground.swift draws around them. In the background, with a minute to answer: where
  # macOS waits for someone to allow Automation, osascript would wait with it.
  osascript > "$WORK/finder.log" 2>&1 <<OSA &
tell application "Finder"
  tell disk "$disk"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Lumen.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  local finder=$!
  for attempt in $(seq 1 120); do kill -0 "$finder" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$finder" 2>/dev/null; then
    kill "$finder" 2>/dev/null || true
    echo "Finder did not answer within a minute (Automation not allowed yet?)" >> "$WORK/finder.log"
  fi
  local answered=0
  wait "$finder" && answered=1
  [[ -s "$WORK/finder.log" ]] && sed 's/^/finder: /' "$WORK/finder.log" >&2
  (( answered )) || { why="Finder did not lay the window out (finder: lines above)"; return 1; }
  # Finder writes .DS_Store a moment after the window closes.
  for attempt in $(seq 1 20); do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
  [[ -f "$MOUNT/.DS_Store" ]] || { why="Finder kept no layout (.DS_Store)"; return 1; }
  chmod -Rf go-w "$MOUNT" || true
  sync
  hdiutil detach "$MOUNT" -quiet || { why="the writable image did not detach"; return 1; }
  MOUNT=""
  rm -f "$DMG"
  hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" || { why="the image was not compressed"; return 1; }
}

rm -f "$DMG"
if (( PLAIN )); then
  why="--plain"
elif laid_out; then
  why=""
fi
if [[ -n "$why" ]]; then
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force -quiet || true; fi
  MOUNT=""
  [[ "$why" == "--plain" ]] || echo "warning: the image is made plain — the app and the link in Finder's own window: $why" >&2
  rm -f "$DMG"
  hdiutil create -quiet -volname "$VOLUME" -fs HFS+ -format UDZO -imagekey zlib-level=9 -srcfolder "$STAGE" "$DMG"
fi

# 3. What it holds, read back from the image as it will be downloaded.
CHECK="$(hdiutil attach "$DMG" -readonly -nobrowse -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[[ -n "$CHECK" ]] || { echo "error: the finished image did not mount" >&2; exit 1; }
status=0
[[ -d "$CHECK/Lumen.app" ]] || { echo "error: no Lumen.app in the image" >&2; status=1; }
[[ "$(readlink "$CHECK/Applications")" == "/Applications" ]] || { echo "error: no link to /Applications in the image" >&2; status=1; }
[[ "$(find "$CHECK" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ')" == "2" ]] \
  || { echo "error: the image holds more than the app and the link: $(ls "$CHECK")" >&2; status=1; }
codesign --verify --strict --deep "$CHECK/Lumen.app" || { echo "error: the app in the image does not verify" >&2; status=1; }
[[ "$(codesign -d --verbose=4 "$CHECK/Lumen.app" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')" \
   == "$(codesign -d --verbose=4 "$APP" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')" ]] \
  || { echo "error: the app in the image is not the app given" >&2; status=1; }
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  xcrun stapler validate "$CHECK/Lumen.app" >/dev/null 2>&1 || { echo "error: the app's notarization ticket was lost on the way in" >&2; status=1; }
fi
LAYOUT_NOTE="laid out by Finder"
[[ -f "$CHECK/.DS_Store" ]] || LAYOUT_NOTE="plain (Finder's own window)"
hdiutil detach "$CHECK" -quiet || true
CHECK=""
(( status == 0 )) || exit 1
echo "DMG $DMG: Lumen.app and a link to Applications, $LAYOUT_NOTE, $(du -h "$DMG" | cut -f1)"
