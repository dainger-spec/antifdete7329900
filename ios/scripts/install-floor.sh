#!/usr/bin/env bash
# The floor: Lumen for iPhone needs iOS 18 (the owner's decision, after measuring iOS 17.5: there an
# HTTP proxy lets plain-http pages go around it, and a dead one lets them go direct). This checks that
# on an older iOS the app does not install at all, rather than installing and leaking.
#
#   ios/scripts/install-floor.sh <out-dir> [old iOS version, default 17.5]
#
#   red    the same app built for iOS 17.0 must install on the old simulator: that simulator does
#          install apps, so a refusal below is the version's and nothing else's;
#   green  the app as the project builds it says MinimumOSVersion = the project's minimum, is refused
#          on the old simulator with a version error, and installs on the newest one (the build is good).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
OUT="${1:?out dir}"; OLD="${2:-17.5}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/floor.txt"
say() { echo "$@" | tee -a "$LOG"; }
STATUS=0
BUNDLE="io.lumenbrowser.ios"

say "== $(sw_vers -productName) $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')"
command -v xcodegen >/dev/null || brew install xcodegen >/dev/null 2>&1 || { say "no xcodegen"; exit 2; }
(cd "$HERE" && xcodegen generate --quiet) || { say "xcodegen failed"; exit 2; }
FLOOR="$(sed -n 's/^ *iOS: "\([0-9.]*\)".*/\1/p' "$HERE/project.yml" | head -1)"
say "the project's minimum: iOS $FLOOR"

# ---- Simulators: the old iOS (on the image, else downloaded from Apple) and the newest.
runtime() { # version prefix or "newest" -> identifier version
    xcrun simctl list -j runtimes | python3 -c '
import json, sys
want = sys.argv[1]
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform", "iOS") == "iOS" and r.get("isAvailable", True)]
rs.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")), reverse=True)
if want != "newest":
    rs = [r for r in rs if r["version"] == want or r["version"].startswith(want + ".")]
if rs: print(rs[0]["identifier"], rs[0]["version"])' "$1"
}
device() { # runtime identifier -> a new booted iPhone's UDID
    local type
    type="$(xcrun simctl list -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
names = {t["identifier"]: t["name"] for t in data["devicetypes"]}
r = [r for r in data["runtimes"] if r["identifier"] == sys.argv[1]][0]
ok = [t["identifier"] for t in r.get("supportedDeviceTypes", [])] or list(names)
for name in ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"):
    hit = [i for i in ok if names.get(i) == name]
    if hit: print(hit[0]); break
else:
    print([i for i in ok if "iPhone" in names.get(i, "")][-1])' "$1")"
    local udid
    udid="$(xcrun simctl create "Lumen floor" "$type" "$1")" || return 1
    xcrun simctl boot "$udid" >/dev/null 2>&1; xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
    echo "$udid"
}
read -r OLD_RT OLD_VERSION <<<"$(runtime "$OLD")"
if [[ -z "${OLD_RT:-}" ]]; then
    for attempt in 1 2 3; do
        xcodebuild -downloadPlatform iOS -buildVersion "$OLD" >>"$OUT/runtime-download.txt" 2>&1 && break
        sleep 20
    done
    read -r OLD_RT OLD_VERSION <<<"$(runtime "$OLD")"
fi
[[ -n "${OLD_RT:-}" ]] || { say "no iOS $OLD runtime: $(tail -2 "$OUT/runtime-download.txt" 2>/dev/null | tr '\n' ' ')"; exit 2; }
read -r NEW_RT NEW_VERSION <<<"$(runtime newest)"
OLD_DEV="$(device "$OLD_RT")" || { say "cannot create an iOS $OLD_VERSION simulator"; exit 2; }
NEW_DEV="$(device "$NEW_RT")" || { say "cannot create an iOS $NEW_VERSION simulator"; exit 2; }
trap 'for d in "$OLD_DEV" "$NEW_DEV"; do xcrun simctl shutdown "$d" >/dev/null 2>&1; xcrun simctl delete "$d" >/dev/null 2>&1; done' EXIT
say "== simulators: iOS $OLD_VERSION ($OLD_DEV), iOS $NEW_VERSION ($NEW_DEV)"

build() { # name [build settings...] -> path of Lumen.app
    local name="$1"; shift
    xcodebuild build -project "$HERE/Lumen.xcodeproj" -scheme Lumen -sdk iphonesimulator \
        -destination "generic/platform=iOS Simulator" -derivedDataPath "$OUT/dd-$name" "$@" >"$OUT/build-$name.txt" 2>&1 \
        || { grep -E "error:" "$OUT/build-$name.txt" | head -10 | tee -a "$LOG" >&2; return 1; }
    find "$OUT/dd-$name/Build/Products" -maxdepth 2 -name Lumen.app -type d | head -1
}
minimum() { /usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$1/Info.plist" 2>/dev/null; }
installed() { xcrun simctl get_app_container "$1" "$BUNDLE" >/dev/null 2>&1; }   # device -> is the app on it

# ---- Red: built for iOS 17.0, the same app installs on the old simulator. (The core package keeps
# its own minimum, iOS 17: the app's floor is the app target's, and Xcode refuses an app whose minimum
# is below a package's, which would make this build impossible.)
RED_APP="$(build red IPHONEOS_DEPLOYMENT_TARGET=17.0)" || { say "RED INVALID: the iOS 17.0 build failed"; exit 2; }
if xcrun simctl install "$OLD_DEV" "$RED_APP" >"$OUT/install-red.txt" 2>&1; then
    say "RED OK: built for iOS $(minimum "$RED_APP"), the app installs on iOS $OLD_VERSION — the check would see an app that installs there"
    xcrun simctl launch "$OLD_DEV" "$BUNDLE" >>"$OUT/install-red.txt" 2>&1 && say "   (and it starts there: $(tail -1 "$OUT/install-red.txt"))"
    for attempt in 1 2 3; do
        xcrun simctl terminate "$OLD_DEV" "$BUNDLE" >/dev/null 2>&1; sleep 2
        xcrun simctl uninstall "$OLD_DEV" "$BUNDLE" >>"$OUT/install-red.txt" 2>&1
        installed "$OLD_DEV" || break
    done
    # The green check below asks whether the app is on that simulator: it must start from nothing.
    if installed "$OLD_DEV"; then say "RED INVALID: the red build could not be removed from iOS $OLD_VERSION"; exit 1; fi
else
    say "RED INVALID: even the iOS 17.0 build does not install on iOS $OLD_VERSION, so a refusal proves nothing — $(tail -3 "$OUT/install-red.txt" | tr '\n' ' ')"
    exit 1
fi

# ---- Green: the app as the project builds it.
# The project's own minimum, given to every target: the Mac's core (BrowserCore, the root package,
# linked since the sync) names no iOS minimum, and an Xcode older than the main CI's takes an old
# default for it (CI run 8 on macos-26: "SymmetricKey is only available in iOS 13.0 or newer"). It is
# the project's value, read above from project.yml — the check still reads what the app says.
APP="$(build green IPHONEOS_DEPLOYMENT_TARGET="$FLOOR")" || { say "BUILD FAILED"; exit 2; }
MIN="$(minimum "$APP")"
if [[ "$MIN" == "$FLOOR" ]]; then say "the app says MinimumOSVersion $MIN"; else say "NOT GREEN: the app says MinimumOSVersion '$MIN', the project $FLOOR"; STATUS=1; fi
if xcrun simctl install "$NEW_DEV" "$APP" >"$OUT/install-new.txt" 2>&1; then
    say "it installs on iOS $NEW_VERSION (the build is good)"
else
    say "NOT GREEN: it does not install on iOS $NEW_VERSION either — $(tail -3 "$OUT/install-new.txt" | tr '\n' ' ')"; STATUS=1
fi
if xcrun simctl install "$OLD_DEV" "$APP" >"$OUT/install-green.txt" 2>&1; then
    say "NOT GREEN: the app installs on iOS $OLD_VERSION"; STATUS=1
elif grep -q -i -E "minimum|newer|requires|MinimumOSVersion|version" "$OUT/install-green.txt"; then
    say "GREEN: iOS $OLD_VERSION refuses it — $(grep -i -m1 -E "minimum|newer|requires|version" "$OUT/install-green.txt" | cut -c1-240)"
else
    say "NOT GREEN: iOS $OLD_VERSION refuses it, but not for its version — $(tail -3 "$OUT/install-green.txt" | tr '\n' ' ')"; STATUS=1
fi
# What a refused install leaves (run 10: the simulator still reported a container after the refusal).
# The decisive question is whether the app can run there: it must not.
if installed "$OLD_DEV"; then
    LEFT="$(xcrun simctl get_app_container "$OLD_DEV" "$BUNDLE" 2>/dev/null)"
    say "after the refusal the simulator still reports $BUNDLE at $LEFT (MinimumOSVersion '$(minimum "$LEFT")'; executable: $([[ -x "$LEFT/Lumen" ]] && echo yes || echo no))"
    xcrun simctl appinfo "$OLD_DEV" "$BUNDLE" >"$OUT/appinfo-after-refusal.txt" 2>&1
    if xcrun simctl launch "$OLD_DEV" "$BUNDLE" >"$OUT/launch-after-refusal.txt" 2>&1; then
        say "NOT GREEN: and it starts there — $(tail -1 "$OUT/launch-after-refusal.txt")"; STATUS=1
    else
        say "it does not start there — $(grep -m1 -i -E 'error|fail|unable' "$OUT/launch-after-refusal.txt" | cut -c1-240)"
    fi
else
    say "and it is not on that simulator"
fi
say "== status $STATUS"
exit $STATUS
