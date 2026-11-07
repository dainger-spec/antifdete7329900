#!/usr/bin/env bash
# Lumen for iPhone: build, the core's tests and the end-to-end tests on the iOS Simulator, red runs
# first. Used by .github/workflows/ios-app.yml; runs the same on a Mac with Xcode.
#
#   ios/scripts/ci.sh <out-dir> [ios-version|newest]
#
# Every line of ios/scripts/faults.tsv is a planted fault and the test it must break: that test is
# run with the fault (it must FAIL: "RED OK"), then everything runs without faults (it must pass:
# "GREEN"). A fault its test does not catch fails the job ("RED DID NOT FAIL").
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
OUT="${1:?out dir}"; WANT="${2:-newest}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/ci.txt"
say() { echo "$@" | tee -a "$LOG"; }
STATUS=0

say "== $(sw_vers -productName) $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')"
command -v xcodegen >/dev/null || brew install xcodegen >/dev/null 2>&1 || { say "no xcodegen"; exit 2; }
(cd "$HERE" && xcodegen generate --quiet) || { say "xcodegen failed"; exit 2; }

# ---- 1. The core (swift test): reds, then green.
CORE="$HERE/LumenCore"
swift build --package-path "$CORE" --build-tests >"$OUT/core-build.txt" 2>&1 || { tail -40 "$OUT/core-build.txt"; say "CORE BUILD FAILED"; exit 2; }
while IFS=$'\t' read -r fault kind test; do
    [[ "$fault" =~ ^#|^$ ]] && continue
    [[ "$kind" == "core" ]] || continue
    if LUMEN_FAULTS="$fault" swift test --package-path "$CORE" --skip-build --filter "$test" >"$OUT/core-red-$fault.txt" 2>&1; then
        say "RED DID NOT FAIL core $fault: $test passed with the fault"; STATUS=1
    else
        say "RED OK core $fault: $test failed with the fault — $(grep -m1 -o 'error: .*' "$OUT/core-red-$fault.txt" | cut -c1-160)"
    fi
done < "$HERE/scripts/faults.tsv"
if swift test --package-path "$CORE" --skip-build >"$OUT/core-green.txt" 2>&1; then
    say "GREEN core: $(grep -E 'Executed [0-9]+ tests' "$OUT/core-green.txt" | tail -1)"
else
    grep -E "error|failed" "$OUT/core-green.txt" | head -20 | tee -a "$LOG"; say "NOT GREEN core"; STATUS=1
fi

# ---- 2. A simulated iPhone: the reference's screen (iPhone 17 Pro, else 16 Pro), on the iOS asked for.
read -r RUNTIME_ID RUNTIME_VERSION TYPE <<<"$(xcrun simctl list -j | python3 -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)
names = {t["identifier"]: t["name"] for t in data["devicetypes"]}
rs = [r for r in data["runtimes"] if r.get("platform", "iOS") == "iOS" and r.get("isAvailable", True)]
rs.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")), reverse=True)
if want != "newest":
    rs = [r for r in rs if r["version"] == want or r["version"].startswith(want + ".")]
for r in rs:
    supported = {t["identifier"] for t in r.get("supportedDeviceTypes", [])} or set(names)
    for name in ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"):
        hit = [i for i in supported if names.get(i) == name]
        if hit:
            print(r["identifier"], r["version"], hit[0]); sys.exit()
' "$WANT")"
[[ -n "${TYPE:-}" ]] || { say "no iOS runtime $WANT with an iPhone 15/16/17 Pro"; exit 2; }
UDID="$(xcrun simctl create "Lumen CI" "$TYPE" "$RUNTIME_ID")" || { say "cannot create a simulator"; exit 2; }
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
say "== simulator $UDID: $TYPE, iOS $RUNTIME_VERSION"
trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1; [[ -n "${TESTBED:-}" ]] && kill "$TESTBED" 2>/dev/null' EXIT

# ---- 3. The testbed on this Mac: pages, proxies, a geolocation service (steps 2 and 3 use it).
if [[ -f "$HERE/testbed/testbed.py" ]]; then
    for a in 127.0.0.2 127.0.0.3; do sudo -n ifconfig lo0 alias "$a" up 2>/dev/null || true; done
    python3 "$HERE/testbed/testbed.py" --out "$OUT/testbed" >"$OUT/testbed.txt" 2>&1 &
    TESTBED=$!
    sleep 2
fi

# ---- 4. Build once, then the end-to-end tests: reds, then green.
DEST="id=$UDID"
COMMON=(-project "$HERE/Lumen.xcodeproj" -scheme Lumen -destination "$DEST" -derivedDataPath "$OUT/dd")
if ! xcodebuild build-for-testing "${COMMON[@]}" >"$OUT/build.txt" 2>&1; then
    grep -E "error:|warning: .*nearly matches" "$OUT/build.txt" | head -40 | tee -a "$LOG"; say "BUILD FAILED"; exit 2
fi
say "built"
run_ui() { # result-name, fault ('' for none), -only-testing args...
    local name="$1" fault="$2"; shift 2
    rm -rf "$OUT/$name.xcresult"
    TEST_RUNNER_LUMEN_FAULTS="$fault" xcodebuild test-without-building "${COMMON[@]}" "$@" \
        -resultBundlePath "$OUT/$name.xcresult" >"$OUT/$name.txt" 2>&1
}
while IFS=$'\t' read -r fault kind test; do
    [[ "$fault" =~ ^#|^$ ]] && continue
    [[ "$kind" == "ui" ]] || continue
    if run_ui "red-$fault" "$fault" "-only-testing:$test"; then
        say "RED DID NOT FAIL ui $fault: $test passed with the fault"; STATUS=1
    else
        say "RED OK ui $fault: $test failed with the fault — $(grep -m1 -E 'error: -\[|XCTAssert|failed -' "$OUT/red-$fault.txt" | sed 's/.*error: //' | cut -c1-200)"
    fi
done < "$HERE/scripts/faults.tsv"
if run_ui green ""; then
    say "GREEN ui: $(grep -E 'Executed [0-9]+ test' "$OUT/green.txt" | tail -1)"
else
    grep -E "error: -\[|failed -|Test Case .* failed" "$OUT/green.txt" | head -20 | tee -a "$LOG"; say "NOT GREEN ui"; STATUS=1
fi
# What the person saw: the screenshots the tests attached.
xcrun xcresulttool export attachments --path "$OUT/green.xcresult" --output-path "$OUT/screens" >/dev/null 2>&1 \
    && say "screenshots: $(ls "$OUT/screens" | wc -l | tr -d ' ') files" || say "no screenshots exported"
say "== status $STATUS"
exit $STATUS
