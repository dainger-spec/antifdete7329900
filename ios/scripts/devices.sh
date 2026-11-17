#!/usr/bin/env bash
# Lumen for iPhone on the iPhones testers carry (.github/workflows/ios-app.yml, job "devices"): the
# app built once, then DeviceTests — the person's path from the first launch through a page, the tabs,
# the settings, a proxy and the account; every control on the screen and touchable, the app dark — on
# three simulated iPhones in turn, each a corner the main jobs (iPhone 17 Pro, newest iOS, light
# appearance, default text) do not reach:
#
#   small-oldest   the 4.7-inch iPhone SE on the oldest iOS the app installs on (18), light
#   large-dark     the Pro Max on the newest iOS, the iPhone in dark appearance
#   small-largest  the smallest iPhone the newest iOS runs, the largest accessibility text, dark
#
# The app is iPhone only (TARGETED_DEVICE_FAMILY 1) and portrait only: no iPad leg; the test turns the
# iPhone on its side and checks the app stays upright. Legs in turn, not a wider matrix: the macOS
# machines are few and shared. Only small-oldest needs a machine of its own: Xcode 27 has no iOS 18
# simulator ("iOS 18.6 is not available for download", run 143), so the workflow runs that leg on
# macos-26 (Xcode 26, as ios-floor.yml) and the two others on xcode-27.
#
#   ios/scripts/devices.sh <out-dir> [legs, comma-separated; default all three]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
OUT="${1:?out dir}"; LEGS="${2:-small-oldest,large-dark,small-largest}"
mkdir -p "$OUT/screens"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/devices.txt"
say() { echo "$@" | tee -a "$LOG"; }
STATUS=0
SIMS=()
TESTBED=""
trap 'for d in ${SIMS[@]+"${SIMS[@]}"}; do xcrun simctl shutdown "$d" >/dev/null 2>&1; xcrun simctl delete "$d" >/dev/null 2>&1; done; [[ -n "$TESTBED" ]] && kill "$TESTBED" 2>/dev/null; sudo -n rm -f /etc/resolver/lumentest 2>/dev/null' EXIT

say "== $(sw_vers -productName) $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')"
command -v xcodegen >/dev/null || brew install xcodegen >/dev/null 2>&1 || { say "no xcodegen"; exit 2; }
(cd "$HERE" && xcodegen generate --quiet) || { say "xcodegen failed"; exit 2; }

runtimes() { xcrun simctl list -j runtimes | python3 -c '
import json, sys
print(" ".join(r["version"] for r in json.load(sys.stdin)["runtimes"] if r.get("platform", "iOS") == "iOS" and r.get("isAvailable", True)))'; }

# pick <iOS: newest | a major such as 18> <smallest | largest> <device names, in order of preference...>
#   -> "<runtime id> <version> <device type id> <device name with _ for spaces>"
# A major gives its oldest runtime here (the floor); "newest" the newest. Every runtime of that version
# is looked in: Xcode can hold two of one version, one for every iPhone and one made for a single new
# model (run 143: a 27.2 for the "iPhone Duo" alone came first, and both newest legs ran on that
# phone instead of the Pro Max and the smallest). "largest" takes the newest Pro Max first. With none
# of the names there: the iPhone with the smallest or the largest screen in points (the device type's
# profile.plist), so the leg still runs on the screen it is for, and says which iPhone it took.
pick() {
    xcrun simctl list -j | python3 -c '
import json, os, plistlib, re, sys
want, size, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
data = json.load(sys.stdin)
types = {t["identifier"]: t for t in data["devicetypes"]}
name = lambda i: types.get(i, {}).get("name", "")
version = lambda r: tuple(int(x) for x in r["version"].split("."))
rs = [r for r in data["runtimes"] if r.get("platform", "iOS") == "iOS" and r.get("isAvailable", True)]
if want != "newest":
    rs = [r for r in rs if r["version"].split(".")[0] == want]
if not rs:
    sys.exit()
target = (max if want == "newest" else min)(version(r) for r in rs)
# The runtime for every iPhone before one made for a single model.
rs = sorted((r for r in rs if version(r) == target), key=lambda r: -len(r.get("supportedDeviceTypes", [])))
supported = lambda r: [t["identifier"] for t in r.get("supportedDeviceTypes", [])] or list(types)
if size == "largest":
    every = {name(i) for r in rs for i in supported(r)}
    promax = sorted((n for n in every if re.fullmatch(r"iPhone \d+ Pro Max", n)), key=lambda n: -int(n.split()[1]))
    wanted = promax + [n for n in wanted if n not in promax]
for n in wanted:
    for r in rs:
        hit = [i for i in supported(r) if name(i) == n]
        if hit:
            print(r["identifier"], r["version"], hit[0], n.replace(" ", "_")); sys.exit()
def points(i):
    try:
        p = plistlib.load(open(os.path.join(types[i]["bundlePath"], "Contents/Resources/profile.plist"), "rb"))
        return p["mainScreenWidth"] * p["mainScreenHeight"] / p["mainScreenScale"] ** 2
    except Exception:
        return None
r = rs[0]
phones = [i for i in supported(r) if name(i).startswith("iPhone")]
sized = [i for i in phones if points(i)]
if sized:
    i = (min if size == "smallest" else max)(sized, key=points)
elif phones:
    i = phones[0]
else:
    sys.exit()
print(r["identifier"], r["version"], i, name(i).replace(" ", "_"))
' "$@"
}

SMALL=("iPhone SE (3rd generation)" "iPhone SE (2nd generation)" "iPhone 13 mini" "iPhone 12 mini" "iPhone 16e" "iPhone 17e")
LARGE=("iPhone 17 Pro Max" "iPhone 16 Pro Max" "iPhone 15 Pro Max" "iPhone 17 Plus" "iPhone 16 Plus")
say "iOS runtimes on this machine: $(runtimes)"

# The floor: iOS 18. Downloaded when this machine has no iOS 18 runtime (as install-floor.sh does 17.5).
if [[ ",$LEGS," == *",small-oldest,"* && -z "$(pick 18 smallest "${SMALL[@]}")" ]]; then
    for version in 18.6 18.5 18.4 18.2 18.0; do
        say "no iOS 18 runtime here: downloading iOS $version"
        if xcodebuild -downloadPlatform iOS -buildVersion "$version" >>"$OUT/runtime-download.txt" 2>&1; then break; fi
        sleep 20
    done
    say "iOS runtimes after the download: $(runtimes)"
    [[ -n "$(pick 18 smallest "${SMALL[@]}")" ]] || say "the download: $(grep -v '^Finding' "$OUT/runtime-download.txt" | tail -3 | tr '\n' ' ')"
fi

# ---- The testbed (ios/testbed/testbed.py), as ci.sh starts it: the site, the proxies, the account
# server's stand-in, and *.lumentest for this Mac's resolver (the app reaches account.lumentest).
for a in 127.0.0.2 127.0.0.3; do sudo -n ifconfig lo0 alias "$a" up 2>/dev/null || true; done
python3 "$HERE/testbed/testbed.py" --out "$OUT/testbed" >"$OUT/testbed.txt" 2>&1 &
TESTBED=$!
sudo -n mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 28353\n' | sudo -n tee /etc/resolver/lumentest >/dev/null \
    || say "cannot write /etc/resolver/lumentest (sudo?)"
sleep 2
resolve() { dscacheutil -q host -a name "$1" | awk '/ip_address/ {print $2}' | head -1; }
R="$(resolve devices-check-1.lumentest)"
if [[ -z "$R" ]]; then sudo -n killall -HUP mDNSResponder 2>/dev/null; sleep 3; R="$(resolve devices-check-2.lumentest)"; fi
say "this Mac resolves *.lumentest to: ${R:-NOTHING — the sign-in on each iPhone cannot reach the stand-in of the account server}"

# ---- Each leg: a new simulator, its appearance and text size set as a person sets them in Settings.
create() { # leg want smallest|largest look size names... -> sets UDID, DESC
    local leg="$1" want="$2" screen="$3" look="$4" size="$5"; shift 5
    local rt version type name
    read -r rt version type name <<<"$(pick "$want" "$screen" "$@")"
    UDID=""; DESC=""
    [[ -n "${type:-}" ]] || { say "NOT MEASURED $leg: no iOS $want runtime on this machine ($(runtimes))"; return 1; }
    UDID="$(xcrun simctl create "Lumen $leg" "$type" "$rt")" || { say "NOT MEASURED $leg: cannot create a ${name//_/ } on iOS $version"; return 1; }
    SIMS+=("$UDID")
    xcrun simctl boot "$UDID" >/dev/null 2>&1; xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
    xcrun simctl ui "$UDID" appearance "$look" || say "$leg: the appearance could not be set"
    xcrun simctl ui "$UDID" content_size "$size" || say "$leg: the text size could not be set"
    DESC="${name//_/ }, iOS $version, appearance $look, text $size"
}

COMMON=(-project "$HERE/Lumen.xcodeproj" -scheme Lumen -derivedDataPath "$OUT/dd")
BUILT=""
run_leg() { # leg want smallest|largest look size names...
    local leg="$1"
    [[ ",$LEGS," == *",$leg,"* ]] || return 0
    create "$@" || { STATUS=1; return 0; }
    say "== $leg: $DESC ($UDID)"
    if [[ -z "$BUILT" ]]; then
        # Built once, for the first leg's simulator; the others run the same build (iOS 18 and up).
        if ! xcodebuild build-for-testing "${COMMON[@]}" -destination "id=$UDID" >"$OUT/build.txt" 2>&1; then
            grep -E "error:" "$OUT/build.txt" | head -30 | tee -a "$LOG"; say "BUILD FAILED"; exit 2
        fi
        BUILT=1
        say "built"
    fi
    rm -rf "$OUT/$leg.xcresult"
    TEST_RUNNER_LUMEN_DEVICE_LEG="$leg" xcodebuild test-without-building "${COMMON[@]}" -destination "id=$UDID" \
        -only-testing:LumenUITests/DeviceTests -resultBundlePath "$OUT/$leg.xcresult" >"$OUT/$leg.txt" 2>&1 &
    local pid=$! waited=0
    # A leg that hangs (an app that never goes idle: ci.sh's run 35) is stopped after 40 minutes,
    # so the others still run.
    while kill -0 "$pid" 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        if [[ $waited -ge 2400 ]]; then
            xcrun simctl io "$UDID" screenshot "$OUT/screens/stuck-$leg.png" >/dev/null 2>&1
            kill "$pid" 2>/dev/null; sleep 5; kill -9 "$pid" 2>/dev/null
            echo "LUMEN CI: stopped after 40 minutes" >>"$OUT/$leg.txt"
            break
        fi
    done
    wait "$pid"; local code=$?
    if [[ $code -eq 0 ]]; then
        say "GREEN $leg: $(grep -E 'Executed [0-9]+ test' "$OUT/$leg.txt" | tail -1)"
    else
        grep -E "error: -\[|Test Case .* failed|stopped after" "$OUT/$leg.txt" | head -10 | tee -a "$LOG"
        say "NOT GREEN $leg ($DESC)"; STATUS=1
        # What the app and the system said in its last minutes (the app's own lines start "Lumen").
        xcrun simctl spawn "$UDID" log show --last 20m --style compact \
            --predicate 'process == "Lumen" AND (eventMessage CONTAINS "Lumen" OR eventMessage CONTAINS "error")' \
            >"$OUT/$leg-app.log" 2>&1 || true
    fi
    local data; data="$(xcrun simctl get_app_container "$UDID" io.lumenbrowser.ios data 2>/dev/null)"
    [[ -n "$data" && -f "$data/Documents/relay.log" ]] && cp "$data/Documents/relay.log" "$OUT/$leg-relay.log"
    xcrun xcresulttool export attachments --path "$OUT/$leg.xcresult" --output-path "$OUT/screens/$leg" >/dev/null 2>&1 \
        && say "$leg: $(ls "$OUT/screens/$leg" | grep -c png) pictures in screens/$leg" || say "$leg: no pictures exported"
    rm -rf "$OUT/$leg.xcresult"
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1
}

run_leg large-dark newest largest dark large "${LARGE[@]}"
run_leg small-oldest 18 smallest light large "${SMALL[@]}"
run_leg small-largest newest smallest dark accessibility-extra-extra-extra-large "${SMALL[@]}"
say "== status $STATUS"
exit $STATUS
