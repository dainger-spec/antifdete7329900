#!/usr/bin/env bash
# Measurement, stage 1 of iPhone profiles on Apple's iOS Simulator (claude/measure-ios-sim, never
# merged; the owner's questions of 7 November). It builds nothing of the product; it measures:
#   1. the proxy — (a) a proxy setting inside the simulated iOS: the device's own
#      SystemConfiguration preferences, written before it boots; and where a device takes its proxy
#      from at all — the Mac's own setting (CI only: it changes the Mac's proxy for a minute);
#      (b) what the network guard needs: which process holds a device's connection;
#   2. isolation — cookies (script and server), localStorage, IndexedDB and history of two devices;
#   3. cost — disk (Xcode, the runtime, a device), memory per device, boot time, page load as
#      devices are added, until memory runs short or MAX_DEVICES;
#   4. the fingerprint — Resources/fingerprint_probe.js in the device's MobileSafari;
#   5. the screen — whether a process of ours gets a device's frames (scripts/sim_frame_probe.m),
#      and how fast simctl's screenshot is;
#   6. the licence — the Xcode licence text, as this Xcode ships it.
#
#     scripts/ios_sim_stage1.sh [--yes] [--out DIR]
#
# It changes no setting of this Mac except, on a CI runner (CI=true) and only there, the Mac's own
# web proxy for one page load, put back at once. Devices are named "PB stage1 …" and deleted at the
# end. Pages go to names under .invalid (which only the test proxy answers) and to 127.0.0.1.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ASSUME_YES=0
OUT="$PWD/ios-sim-stage1"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) ASSUME_YES=1 ;;
        --out) OUT="$2"; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
HTTP_PORT="${PB_SIM_HTTP_PORT:-28180}"
SOCKS_PORT="${PB_SIM_SOCKS_PORT:-28181}"
PAGE_PORT="${PB_SIM_PAGE_PORT:-28190}"
MAX_DEVICES="${PB_SIM_MAX_DEVICES:-6}"
SAFARI=com.apple.mobilesafari
DOMAIN=pbsim.invalid

fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "this runs on macOS"
xcrun simctl help >/dev/null 2>&1 || fail "xcrun simctl does not run: install Xcode and open it once"
RUN="$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
mkdir -p "$OUT"
REPORTS="$OUT/reports"
mkdir -p "$REPORTS"
if [[ $ASSUME_YES != 1 ]]; then
    read -r -p "This creates and boots up to $MAX_DEVICES simulated iPhones (deleted at the end). Go ahead? [y/N] " answer
    [[ "$answer" == [yY]* ]] || exit 0
fi
exec > >(tee -a "$OUT/stage1.txt") 2>&1
say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pbsim.XXXXXXXX")"
CREATED=()
BACKGROUND=()
HOST_PROXY_SERVICES=()
cleanup() {
    set +e
    for service in ${HOST_PROXY_SERVICES[@]+"${HOST_PROXY_SERVICES[@]}"}; do
        sudo -n networksetup -setwebproxystate "$service" off
        sudo -n networksetup -setsecurewebproxystate "$service" off
    done
    for pid in ${BACKGROUND[@]+"${BACKGROUND[@]}"}; do kill "$pid" 2>/dev/null; done
    for udid in ${CREATED[@]+"${CREATED[@]}"}; do
        xcrun simctl shutdown "$udid" >/dev/null 2>&1
        xcrun simctl delete "$udid" >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

free_mb() { vm_stat | awk '/page size of/ { size = $8 } /Pages (free|inactive|speculative)/ { gsub(/\./, "", $NF); free += $NF } END { printf "%.0f", free * size / 1048576 }'; }

# --- 6 first: the machine, the tools, the licence ------------------------------------------------
DEVELOPER="$(xcode-select -p)"
XCODE_APP="${DEVELOPER%/Contents/Developer}"
say "Run $RUN — $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB memory"
note "Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ') at $XCODE_APP"
note "Xcode on disk: $(du -sh "$XCODE_APP" 2>/dev/null | cut -f1)"
note "free disk: $(df -h / | awk 'NR == 2 { print $4 }')"
xcrun simctl runtime list -j >"$OUT/runtimes.json" 2>/dev/null || true
python3 - "$OUT/runtimes.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
for identifier, r in sorted(data.items(), key=lambda kv: kv[1].get("version", "")):
    print("   runtime image: %s %s (%s), %.2f GB, %s, state %s" % (
        r.get("platformIdentifier", "").split(".")[-1], r.get("version", "?"), r.get("build", "?"),
        (r.get("sizeBytes") or 0) / 1e9, r.get("kind", "?"), r.get("state", "?")))
PY
LICENSE=""
for candidate in "$XCODE_APP/Contents/Resources/en.lproj/License.rtf" "$XCODE_APP/Contents/Resources/English.lproj/License.rtf" \
                 "$XCODE_APP/Contents/Resources/License.rtf"; do
    [[ -f "$candidate" ]] && { LICENSE="$candidate"; break; }
done
[[ -n "$LICENSE" ]] || LICENSE="$(find "$XCODE_APP/Contents/Resources" -maxdepth 2 -iname 'License*.rtf' 2>/dev/null | head -1)"
if [[ -n "$LICENSE" ]]; then
    textutil -convert txt -stdout "$LICENSE" >"$OUT/xcode-license.txt" 2>/dev/null
    note "licence: $LICENSE → xcode-license.txt ($(wc -w <"$OUT/xcode-license.txt") words)"
else
    note "licence: no License.rtf found in $XCODE_APP/Contents/Resources"
fi

RUNTIME_JSON="$(xcrun simctl list -j runtimes)"
read -r RUNTIME_ID RUNTIME_VERSION DEVICE_TYPE_ID DEVICE_NAME < <(printf '%s' "$RUNTIME_JSON" | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin).get("runtimes", []) if r.get("isAvailable") and "iOS" in r.get("identifier", "")]
v = lambda r: tuple(int(p) for p in r.get("version", "0").split(".") if p.isdigit())
best = sorted(rs, key=v)[-1]
phones = [d for d in best.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
print(best["identifier"], best["version"], pro[-1]["identifier"], pro[-1]["name"].replace(" ", "_"))
')
[[ -n "${RUNTIME_ID:-}" ]] || fail "no iOS simulator runtime with an iPhone"
note "device: ${DEVICE_NAME//_/ } on iOS $RUNTIME_VERSION ($RUNTIME_ID)"

# --- The proxy and the pages -----------------------------------------------------------------------
python3 "$HERE/selftest_proxy.py" --http "$HTTP_PORT" --socks "$SOCKS_PORT" >"$WORK/proxy.log" 2>&1 &
BACKGROUND+=("$!")
python3 "$HERE/sim_pages.py" --host 0.0.0.0 --port "$PAGE_PORT" --reports "$REPORTS" >"$WORK/pages.log" 2>&1 &
BACKGROUND+=("$!")
for _ in $(seq 1 40); do lsof -nP -iTCP:"$PAGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:"$HTTP_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
PAGES="http://127.0.0.1:$PAGE_PORT"
LAN_ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
SUDO=0; sudo -n true 2>/dev/null && SUDO=1

proxy_saw() {
    curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$HTTP_PORT/pb-leak/log.json?run=$RUN" | python3 -c '
import json, sys
try: entries = json.load(sys.stdin).get("targets", [])
except ValueError: entries = []
for e in entries:
    if sys.argv[1] in e.get("target", ""): print(e.get("via", ""), e.get("target", ""), e.get("path", ""))
' "$1"
}
wait_for_proxy() { local seen=""; for _ in $(seq 1 "$2"); do seen="$(proxy_saw "$1")"; [[ -n "$seen" ]] && break; sleep 1; done; printf '%s' "$seen"; }
wait_report() {  # $1: report name, $2: seconds; prints the seconds it took, or "none"
    local started; started=$(python3 -c 'import time; print(time.time())')
    for _ in $(seq 1 $(( $2 * 4 ))); do
        if [[ -s "$REPORTS/$1.json" ]]; then python3 -c "import time; print('%.1f' % (time.time() - $started))"; return; fi
        sleep 0.25
    done
    echo none
}

new_device() { NEW_UDID="$(xcrun simctl create "PB stage1 $1 $RUN" "$DEVICE_TYPE_ID" "$RUNTIME_ID")" || fail "simctl create failed"; CREATED+=("$NEW_UDID"); }
device_dir() { echo "$HOME/Library/Developer/CoreSimulator/Devices/$1"; }
boot() {
    local started=$(date +%s)
    xcrun simctl boot "$1" >/dev/null 2>&1
    xcrun simctl bootstatus "$1" >/dev/null 2>&1
    echo $(( $(date +%s) - started ))
}
open_url() { xcrun simctl openurl "$1" "$2" >/dev/null 2>&1 || note "openurl failed for $2"; }
device_pids() {
    local root; root="$(pgrep -f "launchd_sim.*$1" | head -1 || true)"
    [[ -n "$root" ]] || return 0
    ps -axo pid=,ppid= | python3 -c '
import sys
root = int(sys.argv[1]); children = {}
for line in sys.stdin:
    pid, ppid = (int(x) for x in line.split()); children.setdefault(ppid, []).append(pid)
todo, seen = [root], []
while todo:
    pid = todo.pop(); seen.append(pid); todo.extend(children.get(pid, []))
print(" ".join(map(str, sorted(seen))))' "$root"
}
device_footprint_mb() {  # physical footprint of every process of device $1, summed (top's MEM)
    local pids; pids="$(device_pids "$1")"
    [[ -n "$pids" ]] || { echo 0; return; }
    { echo "$pids"; top -l 1 -stats pid,mem 2>/dev/null; } | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines(); pids = set(int(p) for p in lines[0].split())
units = {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}; total = 0.0
for line in lines[1:]:
    parts = line.split()
    if len(parts) >= 2 and parts[0].isdigit() and int(parts[0]) in pids:
        m = re.match(r"([\d.]+)([BKMG])", parts[1])
        if m: total += float(m.group(1)) * units[m.group(2)]
print("%.0f" % total)'
}

# --- 1a. A proxy setting inside the simulated iOS ----------------------------------------------
say "1a. A proxy inside the simulated iOS"
new_device A; A=$NEW_UDID
note "device A $A: booted in $(boot "$A") s"
note "the Mac's own proxy: $(scutil --proxy | tr -s ' \n' ' ' | head -c 300)"
note "the device's view (scutil inside the device): $(xcrun simctl spawn "$A" scutil --proxy 2>&1 | tr -s ' \n' ' ' | head -c 300)"
SC="$(device_dir "$A")/data/Library/Preferences/SystemConfiguration"
note "the device's SystemConfiguration folder: $(ls "$SC" 2>/dev/null | tr '\n' ' ')"
for f in "$SC"/*.plist; do [[ -f "$f" ]] && { echo "   --- $(basename "$f")"; plutil -p "$f" 2>/dev/null | head -60 | sed 's/^/   /'; }; done
open_url "$A" "http://before-$RUN.$DOMAIN/"
note "baseline, no proxy anywhere: the proxy saw [$(wait_for_proxy "before-$RUN" 10)] (must be empty)"
xcrun simctl shutdown "$A" >/dev/null 2>&1
mkdir -p "$SC"
python3 - "$SC/preferences.plist" "$HTTP_PORT" <<'PY'
import os, plistlib, sys, uuid
path, port = sys.argv[1], int(sys.argv[2])
proxies = {"HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
           "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port, "ExceptionsList": [], "FTPPassive": 1}
prefs = plistlib.load(open(path, "rb")) if os.path.exists(path) else {}
services = prefs.setdefault("NetworkServices", {})
if not services:
    sid, set_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    services[sid] = {"Interface": {"DeviceName": "en0", "Hardware": "Ethernet", "Type": "Ethernet", "UserDefinedName": "Ethernet"},
                     "IPv4": {"ConfigMethod": "DHCP"}, "UserDefinedName": "Ethernet"}
    prefs["Sets"] = {set_id: {"Network": {"Service": {sid: {"__LINK__": "/NetworkServices/" + sid}},
                                          "Global": {"IPv4": {"ServiceOrder": [sid]}}}, "UserDefinedName": "Automatic"}}
    prefs["CurrentSet"] = "/Sets/" + set_id
for service in services.values():
    service["Proxies"] = dict(proxies)
plistlib.dump(prefs, open(path, "wb"))
print("   wrote %d service(s) with an HTTP and HTTPS proxy into %s" % (len(services), path))
PY
note "device A booted again in $(boot "$A") s"
note "the device's view now: $(xcrun simctl spawn "$A" scutil --proxy 2>&1 | tr -s ' \n' ' ' | head -c 300)"
open_url "$A" "http://inside-$RUN.$DOMAIN/"
INSIDE="$(wait_for_proxy "inside-$RUN" 20)"
note "a proxy written into the device's own settings: the proxy saw [$INSIDE]"
[[ -n "$INSIDE" ]] && echo "PROXY-INSIDE YES" || echo "PROXY-INSIDE NO"

if [[ "${CI:-}" == true ]]; then
    say "1a'. Where a device takes its proxy from: the Mac's own proxy (CI only, put back at once)"
    while IFS= read -r service; do
        [[ -z "$service" || "$service" == *"asterisk"* ]] && continue
        sudo -n networksetup -setwebproxy "$service" 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1 && HOST_PROXY_SERVICES+=("$service")
        sudo -n networksetup -setsecurewebproxy "$service" 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1
    done < <(networksetup -listallnetworkservices | tail -n +2)
    note "the Mac's proxy set on: ${HOST_PROXY_SERVICES[*]:-none}"
    note "the device's view: $(xcrun simctl spawn "$A" scutil --proxy 2>&1 | tr -s ' \n' ' ' | head -c 200)"
    open_url "$A" "http://host-$RUN.$DOMAIN/"
    HOSTSEEN="$(wait_for_proxy "host-$RUN" 20)"
    note "the Mac's proxy: the proxy saw [$HOSTSEEN] from the device"
    for service in ${HOST_PROXY_SERVICES[@]+"${HOST_PROXY_SERVICES[@]}"}; do
        sudo -n networksetup -setwebproxystate "$service" off; sudo -n networksetup -setsecurewebproxystate "$service" off
    done
    HOST_PROXY_SERVICES=()
    [[ -n "$HOSTSEEN" ]] && echo "PROXY-FROM-MAC YES" || echo "PROXY-FROM-MAC NO"
fi

# --- 1b. What the network guard needs: whose connection it is ------------------------------------
say "1b. Which process holds a device's connection, and what the kernel counts it for"
ancestry() {  # $1: pid — the chain of parents up to launchd, with the device named where it is one
    local pid=$1 chain=""
    while [[ -n "$pid" && "$pid" != 0 && "$pid" != 1 ]]; do
        local line; line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || break
        local ppid="${line%% *}"; line="${line#* }"; ppid="$(echo "$ppid" | tr -d ' ')"
        local name; name="$(basename "$(echo "$line" | sed 's/^ *//')")"
        if [[ "$name" == launchd_sim ]]; then
            name="launchd_sim[$(ps -o args= -p "$pid" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)]"
        fi
        chain="$chain → $name($pid)"
        pid="$ppid"
    done
    echo "${chain# → }"
}
holders() {  # the processes holding client ends of connections to the page server now
    lsof -nP -iTCP:"$PAGE_PORT" -sTCP:ESTABLISHED -F pcn 2>/dev/null | awk -v port=":$PAGE_PORT" '
        /^p/ { pid = substr($0, 2) } /^c/ { cmd = substr($0, 2) }
        /^n/ { name = substr($0, 2); split(name, ends, "->"); if (index(ends[2], port) > 0) print pid " " cmd }' | sort -u
}
if [[ $SUDO == 1 ]]; then
    sudo -n tcpdump -i pktap,lo0 -k NP -n -tt -l "tcp port $PAGE_PORT and tcp[tcpflags] & tcp-syn != 0" >"$WORK/pktap-pages.txt" 2>/dev/null &
    TCPDUMP=$!; BACKGROUND+=("$TCPDUMP"); sleep 2
fi
for d in A; do
    open_url "$A" "$PAGES/hold?dev=$d"
    sleep 6
    holders | while read -r pid command; do
        echo "   device $d's page connection held by $command($pid): $(ancestry "$pid")"
    done
done
if [[ $SUDO == 1 ]]; then
    sleep 1; sudo -n kill "$TCPDUMP" 2>/dev/null
    note "the kernel's record of those connections (pktap: proc = the socket's process, eproc = whom it is counted for):"
    sed 's/^/     /' "$WORK/pktap-pages.txt" | head -12
    note "DNS: device A looks up a name of its own; who asks the resolver, and for whom"
    sudo -n tcpdump -i pktap,all -k NP -n -tt -l "udp port 53 or tcp port 53" >"$WORK/pktap-dns.txt" 2>/dev/null &
    TCPDUMP=$!; BACKGROUND+=("$TCPDUMP"); sleep 2
    open_url "$A" "http://pbsim-$RUN.example.com/"
    sleep 8; sudo -n kill "$TCPDUMP" 2>/dev/null
    grep -i "pbsim-$RUN" "$WORK/pktap-dns.txt" | sed 's/^/     /' | head -8
    [[ -s "$WORK/pktap-dns.txt" ]] || note "no DNS packet captured"
else
    note "no sudo without a password here: the kernel's record (pktap) and the DNS capture are skipped"
fi

# --- 1c. A processor count of the device's own ------------------------------------------------------
say "1c. hardwareConcurrency: WebKit's own setting for its processor count, given to the device"
rm -f "$REPORTS/probe-cores-before.json" "$REPORTS/probe-cores-after.json"
open_url "$A" "$PAGES/probe?name=probe-cores-before"; note "before: $(wait_report probe-cores-before 60) s"
xcrun simctl spawn "$A" launchctl setenv WTF_numberOfProcessorCores 2 2>&1 | sed 's/^/   setenv: /'
xcrun simctl terminate "$A" "$SAFARI" >/dev/null 2>&1
for pid in $(device_pids "$A"); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in *WebContent*|*com.apple.WebKit*) echo "   stopping $(ps -o comm= -p "$pid") ($pid)"; kill "$pid" 2>/dev/null ;; esac
done
sleep 2
open_url "$A" "$PAGES/probe?name=probe-cores-after"; note "after: $(wait_report probe-cores-after 60) s"
python3 - "$REPORTS" <<'PY'
import json, os, sys
for name in ("probe-cores-before", "probe-cores-after"):
    path = os.path.join(sys.argv[1], name + ".json")
    if os.path.exists(path):
        p = json.load(open(path))
        print("   %s: page %s, worker %s" % (name, p.get("hardwareConcurrency"), p.get("_page", {}).get("workerHardwareConcurrency")))
    else:
        print("   %s: no report" % name)
PY
xcrun simctl spawn "$A" launchctl unsetenv WTF_numberOfProcessorCores >/dev/null 2>&1

# --- 2. Isolation --------------------------------------------------------------------------------
say "2. Isolation of two devices"
new_device B; B=$NEW_UDID
note "device B $B: booted in $(boot "$B") s"
open_url "$A" "$PAGES/iso/set?dev=A"; note "A set: $(wait_report iso-set-A 30) s"
open_url "$A" "$PAGES/iso/get?dev=A"; note "A read its own: $(wait_report iso-get-A 30) s"
open_url "$B" "$PAGES/iso/get?dev=B"; note "B read: $(wait_report iso-get-B 30) s"
for name in iso-set-A iso-get-A iso-get-B; do note "$name: $(cat "$REPORTS/$name.json" 2>/dev/null || echo none)"; done
note "Cookie headers per request:"
grep '"/iso/' "$REPORTS/requests.jsonl" | python3 -c '
import json, sys
for line in sys.stdin:
    r = json.loads(line); print("     %s %s cookie=[%s]" % (r["method"], r["path"], r["cookie"]))'
sleep 3
for d in A B; do
    udid=${!d}
    note "history files of device $d (MobileSafari's History.db), rows naming /iso/set:"
    find "$(device_dir "$udid")/data" -name 'History.db' 2>/dev/null | while read -r db; do
        rows="$(sqlite3 "file:$db?mode=ro" "select count(*) from history_items where url like '%/iso/set%';" 2>&1)"
        echo "     $db: $rows"
    done
done

# --- 4. The fingerprint ---------------------------------------------------------------------------
say "4. The fingerprint probe in MobileSafari"
open_url "$A" "$PAGES/probe?name=probe-simulator"
note "probe (loopback, a secure context): $(wait_report probe-simulator 60) s"
if [[ -n "$LAN_ADDRESS" ]]; then
    open_url "$A" "http://$LAN_ADDRESS:$PAGE_PORT/probe?name=probe-simulator-lan"
    note "probe over plain http on this Mac's network address ($LAN_ADDRESS), as the real iPhone's: $(wait_report probe-simulator-lan 60) s"
fi
[[ -s "$REPORTS/probe-simulator.json" ]] && python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
for k in ("ua", "platform", "hardwareConcurrency", "maxTouchPoints", "screen", "webgl", "_page"):
    print("   %s: %s" % (k, json.dumps(p.get(k))[:400]))' "$REPORTS/probe-simulator.json"

# --- 5. The screen --------------------------------------------------------------------------------
say "5. The device's screen, outside Simulator.app"
open_url "$A" "$PAGES/anim"
sleep 2
if clang -fobjc-arc -framework Foundation -framework AppKit -framework IOSurface -framework CoreImage -framework CoreGraphics -framework ImageIO \
        "$HERE/sim_frame_probe.m" -o "$WORK/sim_frame_probe" 2>"$WORK/clang.err"; then
    "$WORK/sim_frame_probe" "$A" "$DEVELOPER" "$OUT/frame-A.png" 2>&1 | grep -v '^FRAME   ROCK\|^FRAME port' | head -60
    note "the page's own count of frames drawn: $(wait_report anim 30) s → $(cat "$REPORTS/anim.json" 2>/dev/null)"
    SIMKIT="$(find "$XCODE_APP" /Library/Developer/PrivateFrameworks -name SimulatorKit.framework -maxdepth 8 2>/dev/null | head -1)"
    note "SimulatorKit: ${SIMKIT:-not found}"
    if [[ -n "$SIMKIT" ]]; then
        open_url "$A" "$PAGES/tap"; sleep 3
        "$WORK/sim_frame_probe" "$A" "$DEVELOPER" "$WORK/unused.png" --tap "$SIMKIT/SimulatorKit" 2>&1 | grep -v '^FRAME   ROCK' | head -60
        note "exit status of the tap: $?"
        note "what the page saw of the tap: $(wait_report tap 10) s → $(cat "$REPORTS/tap.json" 2>/dev/null || echo nothing)"
    fi
else
    note "the frame probe did not build: $(head -5 "$WORK/clang.err")"
fi
start=$(python3 -c 'import time; print(time.time())')
for i in 1 2 3 4 5; do xcrun simctl io "$A" screenshot "$WORK/shot$i.png" >/dev/null 2>&1; done
note "simctl io screenshot: $(python3 -c "import time; print('%.2f' % ((time.time() - $start) / 5))") s a frame"
cp "$WORK/shot5.png" "$OUT/screenshot-A.png" 2>/dev/null

# --- 3. Cost, and how many at once ----------------------------------------------------------------
say "3. Cost of a device, and how many run at once"
note "Mac free memory with devices A and B booted: $(free_mb) MB"
for d in A B; do
    udid=${!d}
    note "device $d: footprint $(device_footprint_mb "$udid") MB over $(device_pids "$udid" | wc -w | tr -d ' ') processes, disk $(du -sh "$(device_dir "$udid")" 2>/dev/null | cut -f1)"
done
xcrun simctl shutdown "$B" >/dev/null 2>&1
BOOTED=("$A")
echo "   devices | boot s | page s (new) | page s (device A) | footprint total MB | free MB"
[[ "${PB_SIM_SKIP_CAPACITY:-}" == 1 ]] && MAX_DEVICES=0
for (( n = 2; n <= MAX_DEVICES; n++ )); do
    if (( $(free_mb) < 1200 )); then note "stopping: $(free_mb) MB free"; break; fi
    new_device "N$n"; u=$NEW_UDID
    secs="$(boot "$u")"
    BOOTED+=("$u")
    open_url "$u" "$PAGES/plain?tag=n$n"; page="$(wait_report "plain-n$n" 90)"
    rm -f "$REPORTS/plain-a$n.json"; open_url "$A" "$PAGES/plain?tag=a$n"; pageA="$(wait_report "plain-a$n" 90)"
    total=0; for b in "${BOOTED[@]}"; do total=$(( total + $(device_footprint_mb "$b") )); done
    echo "   $n | $secs | $page | $pageA | $total | $(free_mb)"
done
note "disk of the devices made: $(du -sh "$HOME/Library/Developer/CoreSimulator/Devices" 2>/dev/null | cut -f1) in all"
say "Done: $OUT"
