#!/bin/bash
# The disk image the website offers (the owner, 1 November): Lumen and a link to Applications,
# laid out so that what to do is plain — drag the one onto the other. From a zip, people leave
# the app in Downloads, where macOS runs it translocated and an update cannot replace it.
#
#   scripts/make_dmg.sh path/to/Lumen.app path/to/Lumen-1.2.3.dmg [--layout required|optional]
#
# The window's layout — the picture behind it (`Lumen --render-dmg-background`), the icons' size
# and places — is Finder's to keep, in the image's .DS_Store, and only Finder writes it: this
# script asks Finder over AppleScript while the image is mounted (Automation: on the release's Mac
# macOS asks once whether Terminal may control Finder). `--layout required` (a release) fails when
# Finder cannot be asked; `optional` (CI's dry run) says so and makes the image without it.
# Nothing is installed for this: hdiutil, osascript, tiffutil and xattr come with macOS.
#
# The app is copied as it is — signed, notarized and stapled before this — and the image is
# compressed read-only (UDZO). Signing, notarizing and stapling the image itself is release.sh's.
set -euo pipefail

APP="${1:?the app bundle}"
DMG="${2:?the disk image to write}"
LAYOUT="optional"
if [[ "${3:-}" == "--layout" ]]; then LAYOUT="${4:?required or optional}"; fi
[[ -d "$APP" && -x "$APP/Contents/MacOS/Lumen" ]] || { echo "error: $APP is not Lumen.app" >&2; exit 1; }
[[ "$DMG" == *.dmg ]] || { echo "error: $DMG does not end in .dmg" >&2; exit 1; }

VOLUME="Lumen"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. What the image holds: the app, the link, the window's picture, the volume's icon.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Lumen.app"
ln -s /Applications "$STAGE/Applications"
"$APP/Contents/MacOS/Lumen" --render-dmg-background "$WORK/background" >/dev/null
# One picture for both kinds of screen (Finder takes the 2x page on a Retina display).
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"; fi

# 2. A writable image of it, mounted where Finder sees it.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 64 ))
hdiutil create -quiet -volname "$VOLUME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -srcfolder "$STAGE" "$WORK/rw.dmg"
# Another volume named Lumen would put this one at "/Volumes/Lumen 1": the mount point is read.
MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[[ -n "$MOUNT" && -d "$MOUNT" ]] || { echo "error: the image did not mount" >&2; exit 1; }
DISK_NAME="$(basename "$MOUNT")"
# The volume's own icon: the Finder flag "has a custom icon" (0x0400) on the volume's root.
if [[ -f "$MOUNT/.VolumeIcon.icns" ]]; then
  xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT" || true
fi

# 3. The window, as Finder keeps it (positions are the icons' centres; DiskImageBackground.swift).
laid_out=0
# In the background, with a minute to answer: where macOS waits for someone to allow Automation,
# osascript would wait with it.
osascript > "$WORK/finder.log" 2>&1 <<OSA &
tell application "Finder"
  tell disk "$DISK_NAME"
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
    set position of item "Lumen.app" of container window to {170, 180}
    set position of item "Applications" of container window to {490, 180}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
FINDER_PID=$!
for attempt in $(seq 1 120); do kill -0 "$FINDER_PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$FINDER_PID" 2>/dev/null; then
  kill "$FINDER_PID" 2>/dev/null || true
  echo "Finder did not answer within a minute" >> "$WORK/finder.log"
fi
if wait "$FINDER_PID"; then
  # Finder writes .DS_Store a moment after the window closes.
  for attempt in $(seq 1 20); do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
  [[ -f "$MOUNT/.DS_Store" ]] && laid_out=1
fi
[[ -s "$WORK/finder.log" ]] && sed 's/^/finder: /' "$WORK/finder.log" >&2
if (( ! laid_out )); then
  if [[ "$LAYOUT" == "required" ]]; then
    echo "error: Finder did not lay out the image's window (Automation: may Terminal control Finder?)" >&2
    exit 1
  fi
  echo "warning: Finder did not lay out the image's window: the image has the app and the link, in Finder's own order" >&2
fi
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# 4. Compressed, read-only.
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

# 5. What it holds, read back from the image as it will be downloaded.
CHECK="$(hdiutil attach "$DMG" -readonly -nobrowse -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[[ -n "$CHECK" ]] || { echo "error: the finished image did not mount" >&2; exit 1; }
status=0
[[ -d "$CHECK/Lumen.app" ]] || { echo "error: no Lumen.app in the image" >&2; status=1; }
[[ "$(readlink "$CHECK/Applications")" == "/Applications" ]] || { echo "error: no link to /Applications in the image" >&2; status=1; }
codesign --verify --strict --deep "$CHECK/Lumen.app" || { echo "error: the app in the image does not verify" >&2; status=1; }
[[ "$(codesign -d --verbose=4 "$CHECK/Lumen.app" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')" \
   == "$(codesign -d --verbose=4 "$APP" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')" ]] \
  || { echo "error: the app in the image is not the app given" >&2; status=1; }
if [[ -f "$APP/Contents/CodeResources" || -d "$APP/Contents/_CodeSignature" ]] && xcrun stapler validate "$APP" >/dev/null 2>&1; then
  xcrun stapler validate "$CHECK/Lumen.app" >/dev/null 2>&1 || { echo "error: the app's notarization ticket was lost on the way in" >&2; status=1; }
fi
LAYOUT_NOTE="laid out by Finder"
[[ -f "$CHECK/.DS_Store" ]] || LAYOUT_NOTE="NOT laid out (Finder's default window)"
hdiutil detach "$CHECK" -quiet || true
(( status == 0 )) || exit 1
echo "DMG $DMG: Lumen.app and Applications, $LAYOUT_NOTE, $(du -h "$DMG" | cut -f1)"
