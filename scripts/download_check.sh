#!/bin/bash
# The disk image as someone downloads it, on a Mac that has never seen Lumen (the owner, 1 November:
# it must open without a word about an unidentified developer).
#
#   scripts/download_check.sh https://dl.lumenbrowser.io/Lumen-1.2.3.dmg --expect accepted
#   scripts/download_check.sh build/release/Lumen-0.1.1.dmg --expect rejected     (CI's control)
#
# The image is fetched (or copied) and marked as a browser marks a download (com.apple.quarantine,
# as Safari writes it), then judged as macOS judges it when it is opened: Gatekeeper's verdict on
# the image (spctl, the context a download is opened in) and its stapled ticket; mounted, the app
# inside, copied out and marked the same way, judged as at its first launch (spctl --type execute;
# syspolicy_check where this macOS has it). `accepted` wants all of it to pass and Gatekeeper to say
# "Notarized Developer ID"; `rejected` wants Gatekeeper to refuse — an image that is not notarized
# is the control that shows this check can fail (and that Gatekeeper is on, on this Mac).
set -uo pipefail

SOURCE="${1:?the address or the file of the disk image}"
EXPECT="accepted"
if [[ "${2:-}" == "--expect" ]]; then EXPECT="${3:?accepted or rejected}"; fi
[[ "$EXPECT" == accepted || "$EXPECT" == rejected ]] || { echo "error: --expect accepted|rejected" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-download.XXXXXX")"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
DMG="$WORK/Lumen.dmg"
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
pass() { echo "PASS $*"; }

echo "Gatekeeper on this Mac: $(spctl --status 2>&1)"
if [[ "$SOURCE" == https://* ]]; then
  curl --fail --silent --show-error --location -o "$DMG" "$SOURCE" || { echo "error: $SOURCE could not be downloaded" >&2; exit 2; }
else
  cp "$SOURCE" "$DMG" || exit 2
fi
echo "image: $(stat -f%z "$DMG") bytes, SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
quarantine() { xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$1"; }
quarantine "$DMG"

# The image, as it is opened from Downloads.
image_verdict="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1)"
image_status=$?
echo "spctl (image): $image_verdict"
if [[ "$EXPECT" == accepted ]]; then
  (( image_status == 0 )) && [[ "$image_verdict" == *"Notarized Developer ID"* ]] \
    && pass "the image is accepted by Gatekeeper, as notarized" || fail "the image is not accepted as notarized"
  xcrun stapler validate "$DMG" >/dev/null 2>&1 && pass "the image carries its notarization ticket (stapled)" \
    || fail "the image has no stapled ticket: opening it offline would ask Apple first"
else
  (( image_status != 0 )) && pass "the control: Gatekeeper refuses an image that is not notarized" \
    || fail "Gatekeeper accepted an image that is not notarized: this Mac cannot judge downloads (is Gatekeeper off?)"
fi

# The app inside, copied out as the person drags it, at its first launch.
MOUNT="$(hdiutil attach "$DMG" -readonly -nobrowse -noverify -noautoopen 2>/dev/null | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
if [[ -z "$MOUNT" ]]; then
  fail "the image did not mount"
else
  [[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] && pass "the image holds a link to Applications" \
    || fail "the image holds no link to Applications"
  mkdir -p "$WORK/Applications"
  ditto "$MOUNT/Lumen.app" "$WORK/Applications/Lumen.app" && quarantine "$WORK/Applications/Lumen.app"
  app_verdict="$(spctl --assess --type execute --verbose=4 "$WORK/Applications/Lumen.app" 2>&1)"
  app_status=$?
  echo "spctl (app): $app_verdict"
  if [[ "$EXPECT" == accepted ]]; then
    (( app_status == 0 )) && [[ "$app_verdict" == *"Notarized Developer ID"* ]] \
      && pass "the app is accepted at its first launch, as notarized" || fail "the app is not accepted as notarized"
    xcrun stapler validate "$WORK/Applications/Lumen.app" >/dev/null 2>&1 && pass "the app carries its own ticket" \
      || fail "the app has no stapled ticket"
    if command -v syspolicy_check >/dev/null; then
      syspolicy_check distribution "$WORK/Applications/Lumen.app" && pass "syspolicy_check distribution: no issue" \
        || fail "syspolicy_check distribution found issues (above)"
    fi
  else
    (( app_status != 0 )) && pass "the control: Gatekeeper refuses the app of an image that is not notarized" \
      || fail "Gatekeeper accepted an app that is not notarized"
  fi
fi

if (( failures )); then
  echo "download check ($EXPECT): $failures failed"
  exit 1
fi
echo "download check ($EXPECT): every check passed"
