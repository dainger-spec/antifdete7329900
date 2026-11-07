#!/usr/bin/env bash
# Stage 1 on the iOS Simulator: builds the driver, boots a simulated iPhone per iOS runtime, runs a
# harness scenario against it. Used by .github/workflows/ios-app-measure.yml; runs the same on any
# Mac with Xcode and an iOS simulator runtime (it asks for sudo once: lo0 aliases and tcpdump).
#
#   ios-measure/run_sim.sh <out-dir> [scenario] [runtimes]
#
# scenario: q1 (default) — red runs first (noproxy, swap, sharestore: each must FAIL), then green.
#           Any other value is a module under ios-measure/host (q2, q3): green only.
# runtimes: "newest" (default), "all", or a comma list of versions (27.1,18.6).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?out dir}"; SCENARIO="${2:-q1}"; WHICH="${3:-newest}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/run.txt"
say() { echo "$@" | tee -a "$LOG"; }

say "== $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
say "== $(xcodebuild -version | tr '\n' ' ')"
xcrun simctl list runtimes | tee -a "$LOG"

# lo0 aliases: proxy A's and B's upstream connections come from addresses of their own.
for a in 127.0.0.2 127.0.0.3; do sudo -n ifconfig lo0 alias "$a" up 2>/dev/null && say "lo0 alias $a" || say "no lo0 alias $a (sudo?)"; done
LAN="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
say "this Mac's address: ${LAN:-none}"
CAPTURE="pktap,all"; sudo -n true 2>/dev/null || CAPTURE=""

# The site's certificate (*.lumentest, self-signed; the driver trusts it for .lumentest only).
cat > "$OUT/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = lumentest
[ext]
subjectAltName = DNS:*.lumentest, DNS:lumentest
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 3 -config "$OUT/cert.cnf" >/dev/null 2>&1

BUILD="$OUT/build"; mkdir -p "$BUILD"
if ! "$HERE/build_sim_app.sh" "$BUILD" 16.0 plain >>"$LOG" 2>&1; then
    say "build for iOS 16.0 failed; trying 17.0"
    "$HERE/build_sim_app.sh" "$BUILD" 17.0 plain >>"$LOG" 2>&1 || { tail -40 "$LOG"; say "BUILD FAILED"; exit 2; }
fi
APP="$BUILD/LumenMeasure.app"
BUNDLE="io.lumenbrowser.measure"
if [[ "$SCENARIO" == "q3" ]]; then   # a second build with WKAppBoundDomains (web.telegram.org, lumentest)
    mkdir -p "$BUILD/bound"
    "$HERE/build_sim_app.sh" "$BUILD/bound" 17.0 bound >>"$LOG" 2>&1 || say "bound build failed"
fi
say "built $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist") minimum"

# Runtimes to measure: identifier and version, newest first.
RUNTIMES="$(xcrun simctl list -j runtimes | python3 -c '
import json, sys
which = sys.argv[1]
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform", "iOS") == "iOS" and r.get("isAvailable", True)]
key = lambda r: tuple(int(x) for x in r["version"].split("."))
rs.sort(key=key, reverse=True)
if which == "newest": rs = rs[:1]
elif which == "majors":
    seen, keep = set(), []
    for r in rs:
        major = r["version"].split(".")[0]
        if major not in seen: seen.add(major); keep.append(r)
    rs = keep
elif which != "all": rs = [r for r in rs if r["version"] in which.split(",")]
for r in rs: print(r["identifier"], r["version"])
' "$WHICH")"
say "runtimes to measure: $(echo $RUNTIMES)"
[[ -n "$RUNTIMES" ]] || { say "no iOS runtime"; exit 2; }

STATUS=0
run_mode() { # udid version mode [label]
    local udid="$1" version="$2" mode="$3" dir="$OUT/ios-$2/$3${4:+-$4}"
    mkdir -p "$dir"
    python3 "$HERE/host/harness.py" --scenario "$SCENARIO" --brk "$mode" --out "$dir" --lan-ip "$LAN" \
        --bind-a 127.0.0.2 --bind-b 127.0.0.3 --cert "$OUT/cert.pem" --key "$OUT/key.pem" \
        --capture "$CAPTURE" --static-dir "$HERE/host/static" --wait-app 180 >"$dir/harness.txt" 2>&1 &
    local harness=$!
    sleep 2
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
    SIMCTL_CHILD_LUMEN_CONTROL="http://127.0.0.1:28310" xcrun simctl launch --console-pty "$udid" "$BUNDLE" >"$dir/app-console.txt" 2>&1 &
    local console=$!
    wait "$harness"; local code=$?
    kill "$console" 2>/dev/null; xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
    grep -E "^(PASS|FAIL|LEAK|INFO|INCONCLUSIVE|SUMMARY)" "$dir/harness.txt" | cut -c1-400 | sed "s/^/[iOS $version $mode] /" | tee -a "$LOG"
    if [[ "$mode" == "none" ]]; then
        [[ $code -eq 0 ]] && say "GREEN iOS $version: every core check passed" || { say "NOT GREEN iOS $version (exit $code)"; STATUS=1; }
    else
        [[ $code -ne 0 ]] && say "RED OK iOS $version $mode: the checks failed on the broken setup, as they must" \
                          || { say "RED DID NOT FAIL iOS $version $mode: the checks cannot tell"; STATUS=1; }
    fi
}

FIRST=1
while read -r RUNTIME VERSION; do
    [[ -n "$RUNTIME" ]] || continue
    TYPE="$(xcrun simctl list -j devicetypes | python3 -c '
import json, sys, subprocess
types = [t for t in json.load(sys.stdin)["devicetypes"] if t.get("productFamily") == "iPhone"]
rt = json.loads(subprocess.run(["xcrun", "simctl", "list", "-j", "runtimes"], capture_output=True, text=True).stdout)
ok = {t["identifier"] for r in rt["runtimes"] if r["identifier"] == sys.argv[1] for t in r.get("supportedDeviceTypes", [])}
cands = [t for t in types if not ok or t["identifier"] in ok]
pro = [t for t in cands if "Pro" in t["name"] and "Max" not in t["name"]]
print((pro or cands)[-1]["identifier"])' "$RUNTIME")"
    UDID="$(xcrun simctl create "Lumen measure $VERSION" "$TYPE" "$RUNTIME")" || { say "cannot create a device on $RUNTIME"; continue; }
    say "== iOS $VERSION: device $UDID ($TYPE)"
    T0=$(date +%s); xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1; say "booted in $(( $(date +%s) - T0 ))s"
    if ! xcrun simctl install "$UDID" "$APP" >>"$LOG" 2>&1; then
        say "install failed on iOS $VERSION (the build's minimum is above this runtime?)"
    else
        if [[ "$SCENARIO" == "q1" && $FIRST -eq 1 ]]; then
            for mode in noproxy swap sharestore; do run_mode "$UDID" "$VERSION" "$mode"; done
        fi
        run_mode "$UDID" "$VERSION" none
        if [[ "$SCENARIO" == "q3" && -d "$BUILD/bound/LumenMeasure.app" ]] && xcrun simctl install "$UDID" "$BUILD/bound/LumenMeasure.app" >>"$LOG" 2>&1; then
            BUNDLE="io.lumenbrowser.measure.bound"; run_mode "$UDID" "$VERSION" none bound; BUNDLE="io.lumenbrowser.measure"
        fi
        FIRST=0
    fi
    # What the simulated device ran while it was up (WebKit's processes per session).
    xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -i webkit | head -20 >"$OUT/ios-$VERSION/webkit-services.txt"
    ps -axo pid,rss,command | grep -E "WebKit\.(Networking|WebContent|GPU)" | grep -v grep | grep "$UDID" >"$OUT/ios-$VERSION/webkit-processes.txt" || true
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1
done <<<"$RUNTIMES"
say "== done, status $STATUS"
exit $STATUS
