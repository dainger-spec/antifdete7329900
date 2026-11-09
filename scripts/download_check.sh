#!/bin/bash
# The disk image as someone downloads it, on a Mac that has never seen Lumen (the owner, 1 and 2
# November: it must open without a word about an unidentified developer).
#
#   scripts/download_check.sh https://dl.lumenbrowser.io/Lumen-1.2.3.dmg --expect accepted [--shots folder]
#   scripts/download_check.sh build/release/Lumen-0.1.1.dmg --expect rejected --shots folder   (CI's control)
#
# The image is fetched (or copied) and marked as a browser marks a download (com.apple.quarantine,
# as Safari writes it), then judged as macOS judges it when it is opened: Gatekeeper's verdict on
# the image (spctl, the context a download is opened in) and its stapled ticket; mounted, the app
# inside, copied out and marked the same way, judged as at its first launch (spctl --type execute;
# syspolicy_check where this macOS has it). `accepted` wants all of it to pass and Gatekeeper to say
# "Notarized Developer ID"; `rejected` wants Gatekeeper to refuse — an image that is not notarized
# is the control that shows this check can fail (and that Gatekeeper is on, on this Mac).
#
# Then what a person does, with `--shots`: the image opened as a double-click opens it, and the app
# opened from Applications as a first launch opens it, the screen captured after each
# (after-opening-the-image.png, after-opening-the-app.png) with what Gatekeeper logged. Nobody
# answers the dialogs; what is on the screen is what the person would be asked. The app is copied to
# Applications as the person drags it, and removed at the end.
set -uo pipefail

SOURCE="${1:?the address or the file of the disk image}"
shift
EXPECT="accepted"
SHOTS=""
while (( $# )); do
  case "$1" in
    --expect) EXPECT="${2:?accepted or rejected}"; shift 2 ;;
    --shots) SHOTS="${2:?a folder for the screens}"; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$EXPECT" == accepted || "$EXPECT" == rejected ]] || { echo "error: --expect accepted|rejected" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-download.XXXXXX")"
MOUNT=""
INSTALLED=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null
  for volume in /Volumes/Lumen*; do [[ -d "$volume" ]] && hdiutil detach "$volume" -force -quiet 2>/dev/null; done
  [[ -n "$INSTALLED" ]] && rm -rf "$INSTALLED"
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
  hdiutil detach "$MOUNT" -force -quiet 2>/dev/null
  MOUNT=""
fi

# What the person sees: the image double-clicked, then the app opened from Applications. The screen
# after each, and what Gatekeeper logged; whether the image mounted is what it let the person do.
if [[ -n "$SHOTS" ]]; then
  mkdir -p "$SHOTS"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  # `open` waits for the answer to Gatekeeper's question about a quarantined file, and nobody
  # answers here (CI run 600 waited 27 minutes): it goes in the background, with a limit of its own.
  OPENERS=""
  person_opens() {
    perl -e 'alarm shift; exec @ARGV' 25 open "$1" >/dev/null 2>&1 &
    OPENERS="$OPENERS $!"
  }
  person_opens "$DMG"
  sleep 10
  screencapture -x "$SHOTS/after-opening-the-image.png" && echo "screen after opening the image: $SHOTS/after-opening-the-image.png"
  opened="$(find /Volumes -maxdepth 1 -name 'Lumen*' 2>/dev/null | head -n 1)"
  if [[ -n "$opened" ]]; then
    echo "the image opened: $opened, as Finder shows it ($(ls "$opened" | tr '\n' ' '))"
  else
    echo "the image did not open: nothing mounted after the double-click"
  fi
  if [[ "$EXPECT" == accepted && -z "$opened" ]]; then fail "the image did not open on a double-click"; fi
  # The app as the person drags it to Applications, then opened as a first launch: what macOS asks.
  if [[ -d "$WORK/Applications/Lumen.app" ]]; then
    if [[ ! -e /Applications/Lumen.app ]]; then
      INSTALLED=/Applications/Lumen.app
      ditto "$WORK/Applications/Lumen.app" "$INSTALLED" && quarantine "$INSTALLED"
      # The image's question, if any, answered by nobody: closed before the app is opened.
      killall CoreServicesUIAgent DiskImageMounter 2>/dev/null
      sleep 2
      person_opens "$INSTALLED"
      sleep 10
      screencapture -x "$SHOTS/after-opening-the-app.png" && echo "screen after opening the app: $SHOTS/after-opening-the-app.png"
      # This copy's own process, not any other process named Lumen (CI run 601 found one and said the
      # app ran while the screen showed it refused).
      if pgrep -f "^$INSTALLED/Contents/MacOS/Lumen" >/dev/null; then
        echo "the app runs from Applications: no question stopped it"
        [[ "$EXPECT" == rejected ]] && fail "the control's app runs from Applications: Gatekeeper let an app that is not notarized start"
      else
        echo "the app did not start from Applications: macOS asks about it, or refused it (the screen shows which)"
      fi
      pkill -f "^$INSTALLED/Contents/MacOS/Lumen" 2>/dev/null
    else
      echo "Applications already holds a Lumen.app: the app's first launch is not shown on this Mac"
    fi
  fi
  perl -e 'alarm shift; exec @ARGV' 90 log show --style compact --start "$since" \
    --predicate 'process == "syspolicyd" OR process == "CoreServicesUIAgent" OR process == "DiskImageMounter"' 2>/dev/null \
    | grep -iE 'notar|assess|gatekeeper|prompt|quarantine|denied|allowed|malware|developer' | head -n 40 > "$SHOTS/gatekeeper-log.txt"
  echo "what Gatekeeper logged ($SHOTS/gatekeeper-log.txt):"
  sed 's/^/  /' "$SHOTS/gatekeeper-log.txt" | cut -c1-300 | head -n 12
  # Leave no dialog and no waiting `open` behind for the next step.
  killall CoreServicesUIAgent 2>/dev/null
  for opener in $OPENERS; do kill "$opener" 2>/dev/null; done
  wait 2>/dev/null
fi

if (( failures )); then
  echo "download check ($EXPECT): $failures failed"
  exit 1
fi
echo "download check ($EXPECT): every check passed"
