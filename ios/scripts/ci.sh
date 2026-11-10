#!/usr/bin/env bash
# Lumen for iPhone: build, the core's tests and the end-to-end tests on the iOS Simulator, red runs
# first. Used by .github/workflows/ios-app.yml; runs the same on a Mac with Xcode.
#
#   ios/scripts/ci.sh <out-dir> [ios-version|newest]
#
# Every line of ios/scripts/faults.tsv is a planted fault and the test it must break: that test is
# run with the fault (it must fail), then everything runs without faults (it must pass: "GREEN").
# A red counts ("RED OK") only if its test failed with the fault, in the check named for that fault
# (faults.tsv, 4th column), and passes in the green run. A fault its test does not catch, a test that
# fails elsewhere or anyway, a red that crashed — each fails the job ("RED DID NOT FAIL",
# "RED OTHER CHECK", "RED UNPROVEN", "RED INVALID").
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
OUT="${1:?out dir}"; WANT="${2:-newest}"
# SUITE: "all" (default), or a comma list of "core", "build" and end-to-end test classes
# (SessionsTests, ...): the workflow runs them as parallel jobs. Each job keeps the order — its reds
# first, then its green. "build" builds the app and its tests and runs none: does it all compile.
SUITE="${SUITE:-all}"
in_suite() { [[ "$SUITE" == "all" || ",$SUITE," == *",$1,"* ]]; }   # core | a test class
ONLY=()
if [[ "$SUITE" != "all" ]]; then
    IFS=',' read -ra PARTS <<<"$SUITE"
    for part in "${PARTS[@]}"; do [[ "$part" == "core" || "$part" == "build" ]] || ONLY+=("-only-testing:LumenUITests/$part"); done
fi
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/ci.txt"
say() { echo "$@" | tee -a "$LOG"; }
STATUS=0

say "== $(sw_vers -productName) $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')"
command -v xcodegen >/dev/null || brew install xcodegen >/dev/null 2>&1 || { say "no xcodegen"; exit 2; }
(cd "$HERE" && xcodegen generate --quiet) || { say "xcodegen failed"; exit 2; }

# ---- 0. The page shim is what its sources make (the macOS app's PrivacyScripts + ios/shim/fingerprint.js).
python3 "$HERE/scripts/build-shim.py" --check | tee -a "$LOG" || { say "page-shim.js is stale"; STATUS=1; }
# The canvas noise is one a canvas can hold (and its control, the old noise, is not).
node "$HERE/shim/test-fingerprint.mjs" | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]] || { say "canvas noise check failed"; STATUS=1; }
# The real-iPhone script's own pieces (run-device.sh): each test reproduces the owner's case with the
# old rule (its red) beside the new one — the device it picks, and a recording that saw nothing. And the
# owner's rules for the App Store build (release_rules.py: none of the positioning words, no App-Bound
# Domains), each red a planted breach.
if in_suite core; then
    for t in test_device_pick.py test_capture_look.py test_release_rules.py; do
        python3 "$HERE/scripts/$t" 2>&1 | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]] || { say "$t failed"; STATUS=1; }
    done
    # The account server's stand-in signs its documents with the testbed's own Ed25519: RFC 8032's vectors.
    python3 "$HERE/testbed/ed25519.py" 2>&1 | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]] || { say "the testbed's Ed25519 is wrong"; STATUS=1; }
fi

# A red run counts only if its test passes without the fault: a test that fails anyway proves nothing
# by failing with it (CI run 5: most reds "failed" where the green run failed too). Reds are therefore
# provisional ("red") until the green run; then each is RED OK or RED UNPROVEN.
REDS=()
verdicts() { # kind, green output: the final word on that kind's reds
    local kind="$1" green="$2" entry fault test id
    for entry in ${REDS[@]+"${REDS[@]}"}; do
        IFS="|" read -r k fault test <<<"$entry"
        [[ "$k" == "$kind" ]] || continue
        id="$(echo "$test" | sed -E 's#^([A-Za-z]+)[./]([A-Za-z]+)/(.*)$#\1.\2 \3#')"   # Module.Class test
        if grep -q "Test Case '-\[$id\]' passed" "$green"; then
            say "RED OK $kind $fault: $test failed with the fault and passes without it"
        else
            say "RED UNPROVEN $kind $fault: $test did not pass without the fault either, so failing with it proves nothing"; STATUS=1
        fi
    done
}

# ---- 1. The core (swift test): reds, then green.
if in_suite core; then
CORE="$HERE/LumenCore"
swift build --package-path "$CORE" --build-tests >"$OUT/core-build.txt" 2>&1 || { tail -40 "$OUT/core-build.txt"; say "CORE BUILD FAILED"; exit 2; }
while IFS=$'\t' read -r fault kind test expect; do
    [[ "$fault" =~ ^#|^$ ]] && continue
    [[ "$kind" == "core" ]] || continue
    if LUMEN_FAULTS="$fault" swift test --package-path "$CORE" --skip-build --filter "$test" >"$OUT/core-red-$fault.txt" 2>&1; then
        say "RED DID NOT FAIL core $fault: $test passed with the fault"; STATUS=1
    else
        first="$(grep -m1 -E 'error: -\[' "$OUT/core-red-$fault.txt" | sed 's/.*error: //')"
        if [[ -n "${expect:-}" && "$first" != *"$expect"* ]]; then
            say "RED OTHER CHECK core $fault: $test failed, but not in the check that must catch it ($expect) — $(echo "$first" | cut -c1-200)"; STATUS=1
        else
            say "red   core $fault: $test failed with the fault — $(echo "$first" | cut -c1-160)"
            REDS+=("core|$fault|$test")
        fi
    fi
done < "$HERE/scripts/faults.tsv"
if swift test --package-path "$CORE" --skip-build >"$OUT/core-green.txt" 2>&1; then
    say "GREEN core: $(grep -E 'Executed [0-9]+ tests' "$OUT/core-green.txt" | tail -1)"
else
    grep -E "error|failed" "$OUT/core-green.txt" | head -20 | tee -a "$LOG"; say "NOT GREEN core"; STATUS=1
fi
verdicts core "$OUT/core-green.txt"
fi
if [[ "$SUITE" != "all" && ${#ONLY[@]} -eq 0 ]] && ! in_suite build; then say "== status $STATUS (core only)"; exit $STATUS; fi

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
trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1; [[ -n "${TESTBED:-}" ]] && kill "$TESTBED" 2>/dev/null; sudo -n rm -f /etc/resolver/lumentest 2>/dev/null; sudo -n pkill -f testbed/dns53.py 2>/dev/null' EXIT

# ---- 3. The testbed on this Mac: pages, proxies, a geolocation service, and a DNS server that
# answers *.lumentest for this Mac's own resolver too — so a page that goes around its proxy loads
# directly and says so (the dead-proxy test), instead of failing unseen at DNS.
if [[ -f "$HERE/testbed/testbed.py" ]]; then
    for a in 127.0.0.2 127.0.0.3; do sudo -n ifconfig lo0 alias "$a" up 2>/dev/null || true; done
    LAN="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
    export TEST_RUNNER_LUMEN_LAN="$LAN"   # the relay's check knocks from this Mac's network address too
    python3 "$HERE/testbed/testbed.py" --out "$OUT/testbed" --lan-address "$LAN" >"$OUT/testbed.txt" 2>&1 &
    TESTBED=$!
    sudo -n mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 28353\n' | sudo -n tee /etc/resolver/lumentest >/dev/null \
        || say "cannot write /etc/resolver/lumentest (sudo?)"
    sleep 2
    resolve() { dscacheutil -q host -a name "$1" | awk '/ip_address/ {print $2}' | head -1; }   # a new name each time: no cached answer
    say "the testbed's DNS asked directly: $(dig +short +time=2 +tries=1 @127.0.0.1 -p 28353 dig-check.lumentest A 2>&1 | head -1)"
    R="$(resolve resolver-check-1.lumentest)"
    if [[ -z "$R" ]]; then   # CI run 10: nothing — mDNSResponder may not have read the new file yet
        sudo -n killall -HUP mDNSResponder 2>/dev/null; sleep 3; R="$(resolve resolver-check-2.lumentest)"
    fi
    if [[ -z "$R" ]]; then   # the standard port: a forwarder (root) on 127.0.0.1:53 to the testbed's DNS
        sudo -n python3 "$HERE/testbed/dns53.py" 28353 >"$OUT/dns53.txt" 2>&1 &
        printf 'nameserver 127.0.0.1\n' | sudo -n tee /etc/resolver/lumentest >/dev/null
        sudo -n killall -HUP mDNSResponder 2>/dev/null; sleep 3; R="$(resolve resolver-check-3.lumentest)"
        say "port 28353 not taken; with a forwarder on port 53: ${R:-still nothing}"
    fi
    scutil --dns | grep -B2 -A5 "lumentest" | head -12 >"$OUT/resolver.txt"
    say "this Mac resolves *.lumentest to: ${R:-NOTHING — the dead-proxy test cannot see a direct connection} ($(tr '\n' ' ' <"$OUT/resolver.txt" | tr -s ' ' | cut -c1-200))"
fi

# The simulator itself: does Safari there reach a .lumentest name directly, and did the testbed get
# the DNS question and the request? (The dead-proxy test's detector depends on it.)
if [[ -n "${TESTBED:-}" ]]; then
    for kind in lo lan; do   # answered with 127.0.0.1 (what the tests use), and with this Mac's address
        probe="probe-$RANDOM.lumentest"; [[ "$kind" == "lan" ]] && probe="lan-$probe"
        xcrun simctl openurl "$UDID" "http://$probe:28380/whoami?t=probe" >/dev/null 2>&1
        sleep 12
        xcrun simctl terminate "$UDID" com.apple.mobilesafari >/dev/null 2>&1
        say "the simulator, Safari to http://$probe (answered with $([[ "$kind" == "lo" ]] && echo 127.0.0.1 || echo "$LAN")): $(python3 - "$OUT/testbed/events.json" "$probe" <<'PY'
import json, sys
try:
    events = json.load(open(sys.argv[1]))
except Exception as e:
    print("no events file", e); sys.exit()
name = sys.argv[2]
dns = [e for e in events if e.get("kind") == "dns" and name in e.get("name", "")]
site = [e for e in events if e.get("kind") == "site" and name in (e.get("host") or "")]
print(f"DNS questions {len(dns)} {[e.get('qtype') for e in dns]}, requests at the site {len(site)} {[(e.get('via'), e.get('peer')) for e in site]}")
PY
)"
    done
fi

# ---- 4. Build once, then the end-to-end tests: reds, then green.
DEST="id=$UDID"
COMMON=(-project "$HERE/Lumen.xcodeproj" -scheme Lumen -destination "$DEST" -derivedDataPath "$OUT/dd")
if ! xcodebuild build-for-testing "${COMMON[@]}" >"$OUT/build.txt" 2>&1; then
    grep -E "error:|warning: .*nearly matches" "$OUT/build.txt" | head -40 | tee -a "$LOG"; say "BUILD FAILED"; exit 2
fi
say "built"
BUILT_APP="$(find "$OUT/dd/Build/Products" -maxdepth 2 -name Lumen.app -type d | head -1)"
# The owner's rules in what was built, not only in the sources (a build phase could add a key).
if in_suite core; then
    python3 "$HERE/scripts/release_rules.py" "$HERE" --app "$BUILT_APP" 2>&1 | tee -a "$LOG"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { say "release rules broken in the built app"; STATUS=1; }
    # A release, built as one would be (the lead, 10 November): without an account it must have no
    # way to the rights a DEBUG build starts with. It is built with a key made for this run in the
    # owner's key's place (the Mac release's dry run does the same), and its binary and Info.plist
    # are checked: no test switch, no exception for the testbed, a key for the documents of rights.
    # The red: the Debug build, given as a release, must be refused.
    RELEASE_KEY="$(python3 - "$HERE/testbed" <<'PY'
import base64, hashlib, os, sys
sys.path.insert(0, sys.argv[1])
import ed25519
public = ed25519.public_key(os.urandom(32))
print(hashlib.sha256(public).digest()[:8].hex() + "=" + base64.b64encode(public).decode())
PY
)"
    if xcodebuild build -project "$HERE/Lumen.xcodeproj" -scheme Lumen -configuration Release -destination "$DEST" \
            -derivedDataPath "$OUT/dd-release" ENTITLEMENT_PUBLIC_KEYS="$RELEASE_KEY" >"$OUT/build-release.txt" 2>&1; then
        RELEASE_APP="$(find "$OUT/dd-release/Build/Products" -maxdepth 2 -name Lumen.app -type d | head -1)"
        python3 "$HERE/scripts/release_rules.py" "$HERE" --release-app "$RELEASE_APP" 2>&1 | tee -a "$LOG"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || { say "release rules broken in the release build"; STATUS=1; }
        if python3 "$HERE/scripts/release_rules.py" "$HERE" --release-app "$BUILT_APP" >"$OUT/release-red.txt" 2>&1; then
            say "RED DID NOT FAIL release rules: the Debug build passed as a release"; STATUS=1
        elif grep -q "test-switch.*LUMEN_TEST_ACCESS" "$OUT/release-red.txt"; then
            say "red   release rules: the Debug build is refused as a release — $(grep -c 'test-switch' "$OUT/release-red.txt") test switches in it, LUMEN_TEST_ACCESS among them"
        else
            say "RED OTHER CHECK release rules: the Debug build was refused, but not for LUMEN_TEST_ACCESS — $(head -3 "$OUT/release-red.txt" | tr '\n' ' ')"; STATUS=1
        fi
        # And a release given no key does not build at all.
        if xcodebuild build -project "$HERE/Lumen.xcodeproj" -scheme Lumen -configuration Release -destination "$DEST" \
                -derivedDataPath "$OUT/dd-release" >"$OUT/build-release-nokey.txt" 2>&1; then
            say "RED DID NOT FAIL: a Release build without ENTITLEMENT_PUBLIC_KEYS was built"; STATUS=1
        elif grep -q "a Release build needs ENTITLEMENT_PUBLIC_KEYS" "$OUT/build-release-nokey.txt"; then
            say "red   a Release build without ENTITLEMENT_PUBLIC_KEYS does not build"
        else
            say "RED OTHER CHECK: the keyless Release build failed for another reason — $(grep -m2 'error' "$OUT/build-release-nokey.txt" | tr '\n' ' ' | cut -c1-200)"; STATUS=1
        fi
        rm -rf "$OUT/dd-release"
    else
        grep -E "error:|error " "$OUT/build-release.txt" | head -30 | tee -a "$LOG"; say "RELEASE BUILD FAILED"; STATUS=1
    fi
fi
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSExceptionDomains:geo.lumentest:NSExceptionAllowsInsecureHTTPLoads" "$BUILT_APP/Info.plist" 2>/dev/null | grep -q true; then
    say "the test build lets the proxy check reach http://geo.lumentest"
else
    say "BUILD WRONG: the test build has no ATS exception for geo.lumentest — every proxy check would fail"; exit 2
fi
if [[ "$SUITE" != "all" && ${#ONLY[@]} -eq 0 ]]; then say "== status $STATUS (built, no end-to-end test asked for)"; exit $STATUS; fi
run_ui() { # result-name, fault ('' for none), -only-testing args...
    local name="$1" fault="$2"; shift 2
    rm -rf "$OUT/$name.xcresult"
    TEST_RUNNER_LUMEN_FAULTS="$fault" xcodebuild test-without-building "${COMMON[@]}" "$@" \
        -resultBundlePath "$OUT/$name.xcresult" >"$OUT/$name.txt" 2>&1 &
    local pid=$!
    # An app that never goes idle (CI run 35, red proxyChangeNotLive: after the first page something
    # in the app kept animating, every step then waited XCTest's 60 s for it, the red took 69 minutes
    # and the job ran out of time). After three such waits its screen is kept and the run is stopped:
    # it says nothing about the check (lost(), below), and the screen shows what kept it busy.
    while kill -0 "$pid" 2>/dev/null; do
        sleep 10
        if [[ "$(grep -c 'animations complete notification not received' "$OUT/$name.txt" 2>/dev/null)" -ge 3 ]]; then
            mkdir -p "$OUT/screens"
            xcrun simctl io "$UDID" screenshot "$OUT/screens/stuck-$name.png" >/dev/null 2>&1
            echo "LUMEN CI: the app never went idle (three 60 s waits) — stopped; screen: screens/stuck-$name.png" >>"$OUT/$name.txt"
            kill "$pid" 2>/dev/null; sleep 5; kill -9 "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid"
    local code=$?
    # The relays' own lines (Documents/relay.log, DEBUG builds): where a slow page spent its time.
    local data; data="$(xcrun simctl get_app_container "$UDID" io.lumenbrowser.ios data 2>/dev/null)"
    [[ -n "$data" && -f "$data/Documents/relay.log" ]] && cp "$data/Documents/relay.log" "$OUT/$name-relay.log"
    return $code
}
lost() { grep -q -E "crashed|Lost connection to the application|Failed to get matching snapshots|Failed to launch|does not have a process ID|is not running|Failed to terminate|never went idle" "$1"; }
while IFS=$'\t' read -r fault kind test expect; do
    [[ "$fault" =~ ^#|^$ ]] && continue
    [[ "$kind" == "ui" ]] || continue
    class="$(echo "$test" | cut -d/ -f2)"; in_suite "$class" || continue
    for try in 1 2; do
        run_ui "red-$fault" "$fault" "-only-testing:$test"; code=$?
        if [[ $code -ne 0 && $try -eq 1 ]] && lost "$OUT/red-$fault.txt"; then
            # The app crashed or was lost (CI run 21: "does not have a process ID" at launch): that says
            # nothing about the check, so the red runs once more; its second run is the one that counts.
            mv "$OUT/red-$fault.txt" "$OUT/red-$fault-lost.txt"
            say "again ui $fault: the app was lost in the first try — $(grep -m1 -E 'crashed|Lost connection|Failed to|process ID|never went idle' "$OUT/red-$fault-lost.txt" | sed 's/.*error: //' | cut -c1-120)"
            continue
        fi
        if [[ $code -eq 0 ]]; then
            say "RED DID NOT FAIL ui $fault: $test passed with the fault"; STATUS=1
        elif lost "$OUT/red-$fault.txt"; then
            # Not "Unable to monitor animations": XCTest prints it right after a test's own relaunch
            # terminates the app (CI run 20, reloadIgnored: the red failed in its own check, and was
            # counted invalid for those lines). A crash or a lost app says so in the words above.
            # A crash fails every test whatever the fault: it proves nothing about the check.
            say "RED INVALID ui $fault: the app crashed or was lost, not the check — $(grep -m1 -E 'crashed|Lost connection|Failed to|never went idle' "$OUT/red-$fault.txt" | sed 's/.*error: //' | cut -c1-160)"; STATUS=1
        else
            # It counts only if the check named for this fault is the one that failed (the first failure:
            # the test stops there), not any other — CI run 12: newTabNotOpened "failed" with the app gone.
            first="$(grep -m1 -E 'error: -\[' "$OUT/red-$fault.txt" | sed 's/.*error: //')"
            if [[ -n "${expect:-}" && "$first" != *"$expect"* ]]; then
                if [[ $try -eq 1 ]]; then
                    # CI run 37 (relayResolvesLocally, relayGapDirect): the testbed served the page, and
                    # the test did not find its text on the screen in time — a step before the named
                    # check failed, or the named check passed blind and a later one caught the fault.
                    # That is the runner, not the check: the first try's log and screens are kept
                    # (red-<fault>-other.txt, screens/other-<fault>), and the red runs once more — its
                    # second run is the one that counts.
                    mv "$OUT/red-$fault.txt" "$OUT/red-$fault-other.txt"
                    xcrun xcresulttool export attachments --path "$OUT/red-$fault.xcresult" --output-path "$OUT/screens/other-$fault" >/dev/null 2>&1
                    say "again ui $fault: the first try failed in another check than the one that must catch it ($expect) — $(echo "$first" | cut -c1-200)"
                    continue
                fi
                say "RED OTHER CHECK ui $fault: $test failed, but not in the check that must catch it ($expect) — $(echo "$first" | cut -c1-200)"; STATUS=1
            else
                say "red   ui $fault: $test failed with the fault — $(echo "$first" | cut -c1-200)"
                REDS+=("ui|$fault|$test")
            fi
        fi
        break
    done
done < "$HERE/scripts/faults.tsv"
run_ui green "" ${ONLY[@]+"${ONLY[@]}"}; GREEN_CODE=$?
if [[ $GREEN_CODE -ne 0 ]] && grep -q "never went idle" "$OUT/green.txt"; then
    # The app stopped going idle for XCTest and the run was stopped (the watchdog above): CI run 35 in a
    # red, run 44 in the green one — FreeTierTests, a session's first page loaded and on the screen,
    # nothing moving in the kept screenshot. That says nothing about a check, so the green run, like
    # a red, runs once more; the first try's log and screen are kept (green-stuck.txt,
    # screens/stuck-green-first.png), and a second stall fails the job.
    mv "$OUT/green.txt" "$OUT/green-stuck.txt"
    [[ -f "$OUT/screens/stuck-green.png" ]] && mv "$OUT/screens/stuck-green.png" "$OUT/screens/stuck-green-first.png"
    say "again ui green: the app never went idle in the first try, in $(grep -E "Test Case .* started" "$OUT/green-stuck.txt" | tail -1 | sed -E "s/.*-\[([^]]*)\].*/\1/") — screen: screens/stuck-green-first.png"
    run_ui green "" ${ONLY[@]+"${ONLY[@]}"}; GREEN_CODE=$?
fi
if [[ $GREEN_CODE -eq 0 ]]; then
    say "GREEN ui: $(grep -E 'Executed [0-9]+ test' "$OUT/green.txt" | tail -1)"
else
    grep -E "error: -\[|failed -|Test Case .* failed|never went idle" "$OUT/green.txt" | head -20 | tee -a "$LOG"; say "NOT GREEN ui"; STATUS=1
fi
verdicts ui "$OUT/green.txt"
# What the person saw: the screenshots the tests attached.
xcrun xcresulttool export attachments --path "$OUT/green.xcresult" --output-path "$OUT/screens" >/dev/null 2>&1 \
    && say "screenshots: $(ls "$OUT/screens" | wc -l | tr -d ' ') files" || say "no screenshots exported"
python3 - "$OUT/testbed/events.json" <<'PY' | tee -a "$LOG"
import json, sys, collections
try:
    events = json.load(open(sys.argv[1]))
except Exception as e:
    print("testbed events: none", e); sys.exit()
dns = collections.Counter(e.get("name", "").split(".")[0].rsplit("-", 1)[0] for e in events if e.get("kind") == "dns")
direct = [e.get("host") for e in events if e.get("kind") == "site" and e.get("via") == "direct" and ".lumentest" in (e.get("host") or "")]
print(f"testbed: DNS questions by name {dict(dns.most_common(12))}; .lumentest pages served directly: {len(direct)} {direct[:6]}")
PY
say "== status $STATUS"
exit $STATUS
