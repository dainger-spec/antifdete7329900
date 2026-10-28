#!/usr/bin/env bash
# SAFARI_GRAPH spike — the owner's check on an ordinary Mac with SIP on (instructions in Russian:
# scripts/safari_graph/MANUAL_CHECK.ru.md). GitHub's macOS runners have SIP off, so CI shows an upper
# bound; this shows what a stock Mac does.
#
# Changes nothing on the system: no SIP or security settings, no sudo, nothing installed. It compiles a
# small probe into a results folder, signs it ad hoc and runs it; with --build or --app it also runs
# the app's new-mode self-test (two windows open for a few seconds).
#
#   scripts/safari_graph/manual_check.sh                  # the probe (Command Line Tools are enough)
#   scripts/safari_graph/manual_check.sh --build          # + build the unsandboxed app, run its self-test
#   scripts/safari_graph/manual_check.sh --app PATH.app   # + self-test an existing SANDBOX=0 build
#   scripts/safari_graph/manual_check.sh --with-ui        # + if Safari.framework loads, try Safari's own UI
#
# --with-ui is off by default: Safari's code then runs in the probe with a throwaway home folder, but it may
# still reach this account's Keychain or iCloud. CI runs it on a throwaway runner.
#
# Results: build/safari-graph-manual-<date>/ and a .zip of it to send back.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD=0
APP=""
UI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build) BUILD=1 ;;
        --with-ui) UI=1 ;;
        --app) shift; APP="${1:-}" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)"; exit 2 ;;
    esac
    shift
done

[ "$(uname)" = "Darwin" ] || { echo "This check runs on macOS only."; exit 1; }
if ! command -v clang >/dev/null 2>&1 || ! command -v codesign >/dev/null 2>&1; then
    echo "The Command Line Tools are missing. Install them with:  xcode-select --install"
    exit 1
fi

OUT="$ROOT/build/safari-graph-manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "Results go to: $OUT"
echo

SIP="$(csrutil status 2>&1)"
echo "$SIP" | tee "$OUT/sip.txt"
case "$SIP" in
    *"status: enabled"*) echo "SIP is on: this is the stock-Mac result the spike needs." ;;
    *) echo "WARNING: SIP is not fully on here. The check still runs, but its results are an upper bound, like CI's." ;;
esac
echo

echo "1/3 How Safari is put together here (facts.txt)…"
"$HERE/facts.sh" > "$OUT/facts.txt" 2>&1

echo "2/3 The load probe under each hardened-runtime exception (probe/)…"
GRAPH_UI="$UI" "$HERE/measure.sh" "$OUT/probe" > "$OUT/probe-console.txt" 2>&1

if [ "$BUILD" = "1" ]; then
    echo "    building the unsandboxed app (several minutes; build.log)…"
    if SANDBOX=0 APP_DIR="$OUT/app" "$ROOT/scripts/build-app.sh" > "$OUT/build.log" 2>&1; then
        APP="$OUT/app/PrivacyBrowser.app"
    else
        echo "    the build failed; see $OUT/build.log (the probe results above still count)"
    fi
fi

if [ -n "$APP" ]; then
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
        echo "3/3 skipped: $APP is the sandboxed build; the new mode needs SANDBOX=0"
    else
        echo "3/3 The new-mode self-test (two windows open for a few seconds; selftest.log)…"
        PB_SELFTEST_SURFACE_OUT="$OUT/surface" "$APP/Contents/MacOS/PrivacyBrowser" --safari-graph-selftest > "$OUT/selftest.log" 2>&1
        echo "    exit code $?" >> "$OUT/selftest.log"
    fi
else
    echo "3/3 skipped: no app (add --build, or --app with a SANDBOX=0 build)"
fi

echo
echo "================ summary ================"
echo "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)); Safari $(defaults read /Applications/Safari.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)"
head -1 "$OUT/sip.txt"
echo "-- Safari.framework in our process, per run (hardened-runtime exception, +env: Safari's staged frameworks):"
awk '/^=================== run: / { if (line != "") print line; line = $3 }
     /^GRAPH (safari_framework_loaded|window_attempt|safari_main|safari_main_windows)=/ {
         sub(/^GRAPH /, ""); line = line "  " $0 }
     /^run .* exit: / { line = line "  exit=" $NF }
     END { if (line != "") print line }' "$OUT/probe/probe.log" 2>/dev/null
echo "-- why Safari.framework did not load (dyld's own words, first distinct reasons):"
grep '^GRAPH dlopen=name=Safari ' "$OUT/probe/probe.log" 2>/dev/null | grep 'result=fail' \
    | sed -e 's/.*err="//' -e 's/dlopen([^)]*): //' | cut -c1-200 | sort -u | head -5
if [ -f "$OUT/selftest.log" ]; then
    echo "-- the app's gate and self-test:"
    grep -E 'safari-graph: gate on this Mac|SAFARI-GRAPH SELFTEST|^FAIL' "$OUT/selftest.log"
fi
( cd "$(dirname "$OUT")" && ditto -c -k --keepParent "$(basename "$OUT")" "$(basename "$OUT").zip" ) \
    && echo && echo "Send this file back: $OUT.zip"
exit 0
