#!/bin/bash
# The disk image the website offers (the owner, 1 and 2 November): Lumen and a link to
# Applications, nothing else. From a zip, people leave the app in Downloads, where macOS runs it
# translocated and an update cannot replace it; the image asks for the drag.
#
#   scripts/make_dmg.sh path/to/Lumen.app path/to/Lumen-1.2.3.dmg
#
# This is the plain image, the release path's first step: Finder shows the two in its own window.
# The window's picture and layout are a change of their own on top of it, so that a failure there
# never stops a release (the owner's order, 2 November).
#
# The app is copied as it is — signed, notarized and stapled before this — into a compressed,
# read-only image (UDZO), and read back from the image as it will be downloaded. Signing,
# notarizing and stapling the image itself is release.sh's. Nothing is installed for this:
# hdiutil, ditto and codesign come with macOS.
set -euo pipefail

APP="${1:?the app bundle}"
DMG="${2:?the disk image to write}"
[[ -d "$APP" && -x "$APP/Contents/MacOS/Lumen" ]] || { echo "error: $APP is not Lumen.app" >&2; exit 1; }
[[ "$DMG" == *.dmg ]] || { echo "error: $DMG does not end in .dmg" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-dmg.XXXXXX")"
CHECK=""
cleanup() {
  if [[ -n "$CHECK" && -d "$CHECK" ]]; then hdiutil detach "$CHECK" -force -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. What the image holds: the app and the link.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lumen.app"
ln -s /Applications "$STAGE/Applications"

# 2. Compressed, read-only.
rm -f "$DMG"
hdiutil create -quiet -volname "Lumen" -fs HFS+ -format UDZO -imagekey zlib-level=9 -srcfolder "$STAGE" "$DMG"

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
hdiutil detach "$CHECK" -quiet || true
CHECK=""
(( status == 0 )) || exit 1
echo "DMG $DMG: Lumen.app and a link to Applications, $(du -h "$DMG" | cut -f1)"
