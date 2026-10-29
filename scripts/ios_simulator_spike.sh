#!/bin/bash
# Spike: can the traffic of ONE simulated iPhone be sent into ITS OWN profile's proxy?
# The question and what each answer means: docs/IOS_SIMULATOR.md.
#
#     scripts/ios_simulator_spike.sh             # says what it will do and asks first
#     scripts/ios_simulator_spike.sh --yes       # no question (a CI job)
#     scripts/ios_simulator_spike.sh --keep      # keep the devices it made, to look at them
#     scripts/ios_simulator_spike.sh --show      # open Simulator.app, to watch the devices
#     scripts/ios_simulator_spike.sh --one       # one device only (less memory; no per-device proof)
#
# Needs a Mac with Xcode and an iOS simulator runtime (iOS 17 or later for the injection check).
# What it does, and nothing else:
#   1. checks the tools and lists the iOS runtimes; it never downloads one (8+ GB: it says how);
#   2. starts on 127.0.0.1 the self-test proxy (scripts/selftest_proxy.py: HTTP CONNECT and SOCKS5;
#      it answers every address itself and connects nowhere) and a small page server that notes
#      which process connected to it;
#   3. creates device A ("PB spike A <run>") with the newest iOS runtime and boots it, headless;
#   4. baseline: Safari opens http://base-<run>.pbspike.invalid/ — a name that resolves nowhere,
#      so without a proxy it cannot load, and the proxy must not see it;
#   5. attribution: Safari opens a page of the page server on 127.0.0.1 (loopback is never
#      proxied); which host process connected, and is it device A's — what a system network
#      extension would have to tell apart;
#   6. environment variables: Safari relaunched with http_proxy, HTTPS_PROXY, … (SIMCTL_CHILD_*);
#   7. library injection: a small dylib, built here for the simulator, gives every WKWebView's
#      data store the proxy (WKWebsiteDataStore.proxyConfigurations, iOS 17+) — what the Mac app
#      does to Safari's chrome; Safari relaunched with DYLD_INSERT_LIBRARIES (SIMCTL_CHILD_*);
#   8. if 7 worked: device B, Safari on the proxy's SOCKS5 side, both devices at once — each
#      device's pages must reach its own proxy only;
#   9. memory of each booted device, the processes of each that reached past loopback, and the
#      verdict.
# It changes no system setting (no proxy setting, certificate, profile or login item); the devices
# live where Xcode keeps its own (~/Library/Developer/CoreSimulator) and are deleted at the end
# unless --keep. Everything it prints also goes to ios-simulator-spike-<run>.txt here.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ASSUME_YES=0 KEEP=0 SHOW=0 ONE=0
for argument in "$@"; do
    case "$argument" in
        --yes) ASSUME_YES=1 ;;
        --keep) KEEP=1 ;;
        --show) SHOW=1 ;;
        --one) ONE=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown argument: $argument (see --help)" >&2; exit 2 ;;
    esac
done

HTTP_PORT="${PB_SPIKE_HTTP_PORT:-28080}"
SOCKS_PORT="${PB_SPIKE_SOCKS_PORT:-28081}"
PAGE_PORT="${PB_SPIKE_PAGE_PORT:-28090}"
SAFARI=com.apple.mobilesafari
DOMAIN=pbspike.invalid

fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 not found. $2"; }

# --- 1. Tools, before anything is created ------------------------------------------------------

[[ "$(uname -s)" == Darwin ]] || fail "this runs on macOS (it drives Xcode's iOS Simulator)"
need xcrun "Install Xcode, open it once, then: sudo xcode-select -s /Applications/Xcode.app"
need python3 "It comes with Xcode's command line tools."
need curl "It is part of macOS."
need lsof "It is part of macOS."
xcrun simctl help >/dev/null 2>&1 || fail "xcrun simctl does not run: open Xcode once (it installs its components), then try again"
[[ -f "$HERE/selftest_proxy.py" ]] || fail "scripts/selftest_proxy.py not found next to this script"
RUN="$(python3 -c 'import secrets; print(secrets.token_hex(5))')"
REPORT="$PWD/ios-simulator-spike-$RUN.txt"

for port in "$HTTP_PORT" "$SOCKS_PORT" "$PAGE_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        fail "port $port on this Mac is taken; set PB_SPIKE_HTTP_PORT / PB_SPIKE_SOCKS_PORT / PB_SPIKE_PAGE_PORT to free ones"
    fi
done

# The newest available iOS runtime, and the newest iPhone it supports.
RUNTIMES_JSON="$(xcrun simctl list -j runtimes)"
CHOICE="$(printf '%s' "$RUNTIMES_JSON" | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin).get("runtimes", [])
            if r.get("isAvailable") and "iOS" in r.get("identifier", "") + r.get("name", "")]
def version(r):
    return tuple(int(p) for p in r.get("version", "0").split(".") if p.isdigit())
for r in sorted(runtimes, key=version):
    print("runtime\t%s\t%s\t%s" % (r["identifier"], r.get("name", ""), r.get("buildversion", "")))
if runtimes:
    best = sorted(runtimes, key=version)[-1]
    phones = [d for d in best.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone" or d.get("name", "").startswith("iPhone")]
    if phones:
        print("choice\t%s\t%s\t%s\t%s" % (best["identifier"], best.get("version", ""), phones[-1]["identifier"], phones[-1]["name"]))
')"
echo "iOS simulator runtimes on this Mac:"
printf '%s\n' "$CHOICE" | awk -F '\t' '$1 == "runtime" { printf "    %s (%s) %s\n", $3, $4, $2 }'
CHOSEN="$(printf '%s\n' "$CHOICE" | awk -F '\t' '$1 == "choice"')"
if [[ -z "$CHOSEN" ]]; then
    fail "no iOS simulator runtime with an iPhone is installed. Xcode → Settings → Components, or
         xcodebuild -downloadPlatform iOS   (about 8–9 GB from Apple; this script never starts it)"
fi
IFS=$'\t' read -r _ RUNTIME_ID RUNTIME_VERSION DEVICE_TYPE_ID DEVICE_TYPE_NAME <<<"$CHOSEN"
RUNTIME_MAJOR="${RUNTIME_VERSION%%.*}"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || echo "?")"

cat <<EOF

This run ($RUN) will, on this Mac:
  - start on 127.0.0.1 the self-test proxy (HTTP CONNECT :$HTTP_PORT, SOCKS5 :$SOCKS_PORT) and a page
    server (:$PAGE_PORT); they answer by themselves and connect nowhere;
  - create and boot $([[ $ONE == 1 ]] && echo "one simulator device" || echo "up to two simulator devices") ($DEVICE_TYPE_NAME, iOS $RUNTIME_VERSION),
    named "PB spike … $RUN", and open pages in their Safari;
  - build a small test library for the simulator in a temporary folder;
  - $([[ $KEEP == 1 ]] && echo "keep the devices at the end (--keep)" || echo "delete the devices at the end, and stop what it started").
It changes no system setting. A booted device takes about 1–2 GB of memory.
EOF
if [[ $ASSUME_YES != 1 ]]; then
    [[ -t 0 ]] || fail "not a terminal: run with --yes to proceed without the question"
    read -r -p "Go ahead? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "Nothing was done."; exit 0; }
fi

exec > >(tee -a "$REPORT") 2>&1
say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pbspike.XXXXXXXX")"
CREATED=()
BACKGROUND=()
cleanup() {
    set +e
    for pid in ${BACKGROUND[@]+"${BACKGROUND[@]}"}; do kill "$pid" 2>/dev/null; done
    for udid in ${CREATED[@]+"${CREATED[@]}"}; do
        if [[ $KEEP == 1 ]]; then
            echo "kept: device $udid (delete it: xcrun simctl delete $udid)"
        else
            xcrun simctl shutdown "$udid" >/dev/null 2>&1
            xcrun simctl delete "$udid" >/dev/null 2>&1 && echo "deleted: device $udid"
        fi
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

say "Run $RUN — $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m), Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}'), iOS simulator SDK $SDK_VERSION"
note "device type: $DEVICE_TYPE_NAME ($DEVICE_TYPE_ID); runtime: iOS $RUNTIME_VERSION ($RUNTIME_ID)"
LAUNCH_HELP="$(xcrun simctl help launch 2>&1 || true)"
if [[ "$LAUNCH_HELP" == *--setenv* ]]; then
    note "simctl launch has --setenv on this Xcode"
else
    note "simctl launch has no --setenv on this Xcode: environment variables go by SIMCTL_CHILD_<name>"
fi

# --- 2. The proxy and the page server ----------------------------------------------------------

say "Starting the self-test proxy and the page server"
python3 "$HERE/selftest_proxy.py" --http "$HTTP_PORT" --socks "$SOCKS_PORT" >"$WORK/proxy.log" 2>&1 &
BACKGROUND+=("$!")
cat >"$WORK/pages.py" <<'PY'
"""A page for every request, noting each connection (its peer port) and keeping it open a while,
so that the process holding the other end can be found with lsof."""
import json, socket, sys, threading, time
port, log_path = int(sys.argv[1]), sys.argv[2]
lock = threading.Lock()
def serve(conn, peer):
    conn.settimeout(3)
    head = b""
    try:
        while b"\r\n\r\n" not in head and len(head) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                break
            head += chunk
    except OSError:
        pass
    line = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    with lock, open(log_path, "a") as log:
        log.write(json.dumps({"time": time.time(), "peer_port": peer[1], "request": line[:300]}) + "\n")
    body = b"<!doctype html><title>PB spike</title><p>PB-SPIKE-PAGE"
    try:
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n" % len(body) + body)
        conn.settimeout(20)
        while conn.recv(4096):
            pass
    except OSError:
        pass
    conn.close()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(64)
while True:
    conn, peer = server.accept()
    threading.Thread(target=serve, args=(conn, peer), daemon=True).start()
PY
python3 "$WORK/pages.py" "$PAGE_PORT" "$WORK/pages.jsonl" >"$WORK/pages.log" 2>&1 &
PAGES_PID=$!
BACKGROUND+=("$PAGES_PID")
for _ in $(seq 1 40); do
    if lsof -nP -iTCP:"$SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:"$PAGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    sleep 0.5
done
lsof -nP -iTCP:"$HTTP_PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "the self-test proxy did not start: $(tail -3 "$WORK/proxy.log")"
note "proxy: HTTP CONNECT 127.0.0.1:$HTTP_PORT, SOCKS5 127.0.0.1:$SOCKS_PORT; pages: 127.0.0.1:$PAGE_PORT"

# What the proxy answered for this run: "via target path" per line, for targets containing $1.
proxy_saw() {
    curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$HTTP_PORT/pb-leak/log.json?run=$RUN" | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin).get("targets", [])
except ValueError:
    entries = []
for e in entries:
    if sys.argv[1] in e.get("target", ""):
        print(e.get("via", ""), e.get("target", ""), e.get("path", ""))
' "$1"
}

# Waits up to $2 seconds for the proxy to see a target containing $1; prints what it saw.
wait_for_proxy() {
    local seen=""
    for _ in $(seq 1 "$2"); do
        seen="$(proxy_saw "$1")"
        [[ -n "$seen" ]] && break
        sleep 1
    done
    printf '%s' "$seen"
}

# --- Devices -----------------------------------------------------------------------------------

# Creates device $1 ("PB spike <letter> <run>") into NEW_UDID — not in a subshell, so that the
# cleanup knows every device made.
new_device() {
    NEW_UDID="$(xcrun simctl create "PB spike $1 $RUN" "$DEVICE_TYPE_ID" "$RUNTIME_ID" 2>"$WORK/create.err")" \
        || fail "the simulator could not create a device: $(cat "$WORK/create.err")"
    CREATED+=("$NEW_UDID")
}

open_url() {  # $1: UDID, $2: address — in the device's Safari
    xcrun simctl openurl "$1" "$2" >/dev/null 2>&1 || note "could not open $2 in the device (simctl openurl failed)"
}

boot() {  # $1: UDID; prints the seconds it took
    local started
    started=$(date +%s)
    if ! xcrun simctl bootstatus "$1" -b >/dev/null 2>&1; then
        xcrun simctl boot "$1" >/dev/null 2>&1 || true
        for _ in $(seq 1 180); do
            [[ "$(xcrun simctl list devices 2>/dev/null)" == *"$1) (Booted)"* ]] && break
            sleep 1
        done
    fi
    printf '%s' "$(( $(date +%s) - started ))"
}

# Relaunches Safari in device $1 with the environment given as NAME=VALUE arguments; prints its pid.
launch_safari() {
    local udid=$1 output
    shift
    xcrun simctl terminate "$udid" "$SAFARI" >/dev/null 2>&1 || true
    sleep 1
    output="$(env "$@" xcrun simctl launch "$udid" "$SAFARI" 2>&1)" || { note "simctl launch failed: $output"; return 0; }
    printf '%s' "${output##*: }"
}

# Every process of device $1: the device's launchd_sim and all below it.
device_pids() {
    local root
    root="$(pgrep -f "launchd_sim.*$1" | head -1 || true)"
    [[ -n "$root" ]] || return 0
    ps -axo pid=,ppid= | python3 -c '
import sys
root = int(sys.argv[1])
children = {}
for line in sys.stdin:
    pid, ppid = (int(x) for x in line.split())
    children.setdefault(ppid, []).append(pid)
todo, seen = [root], []
while todo:
    pid = todo.pop()
    seen.append(pid)
    todo.extend(children.get(pid, []))
print(" ".join(map(str, sorted(seen))))
' "$root"
}

# Memory of device $1: processes, physical footprint (top's MEM) and resident size (RSS), in MB.
device_memory() {
    local pids
    pids="$(device_pids "$1")"
    [[ -n "$pids" ]] || { echo "no processes found"; return 0; }
    {
        echo "PIDS $pids"
        top -l 1 -stats pid,mem 2>/dev/null || true
        echo "RSS"
        # shellcheck disable=SC2086
        ps -o rss= -p "$(echo $pids | tr ' ' ',')" 2>/dev/null || true
    } | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
pids = set(int(p) for p in lines[0].split()[1:])
rss_at = lines.index("RSS")
units = {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}
footprint = 0.0
for line in lines[1:rss_at]:
    parts = line.split()
    if len(parts) >= 2 and parts[0].isdigit() and int(parts[0]) in pids:
        m = re.match(r"([\d.]+)([BKMG])", parts[1])
        if m:
            footprint += float(m.group(1)) * units[m.group(2)]
rss = sum(int(x) for x in lines[rss_at + 1:] if x.strip().isdigit()) / 1024
print("%d processes, footprint %.0f MB, resident %.0f MB" % (len(pids), footprint, rss))
'
}

# The processes of device $1 with a connection past loopback right now, and where to.
device_outside() {
    local pids
    pids="$(device_pids "$1")"
    [[ -n "$pids" ]] || return 0
    # lsof exits 1 when there is none: not a failure here.
    # shellcheck disable=SC2086
    { lsof -nP -i -a -p "$(echo $pids | tr ' ' ',')" 2>/dev/null || true; } \
        | awk 'NR > 1 && $9 !~ /127\.0\.0\.1|\[::1\]|localhost|\*:/ { print "      " $1 " (" $2 ") " $8 " " $9 }' | sort -u | head -40
}

# The host process that holds the client end of a connection to the page server, found while the
# server keeps the connection open: "pid command".
page_client() {
    local found=""
    for _ in $(seq 1 30); do
        found="$({ lsof -nP -iTCP:"$PAGE_PORT" -sTCP:ESTABLISHED -F pc 2>/dev/null || true; } | awk -v server="$PAGES_PID" '
            /^p/ { pid = substr($0, 2) } /^c/ { if (pid != server) { print pid " " substr($0, 2); exit } }')"
        [[ -n "$found" ]] && break
        sleep 0.5
    done
    printf '%s' "$found"
}

memory_before="$(vm_stat | awk '/page size of/ { size = $8 } /Pages (free|inactive|speculative)/ { gsub(/\./, "", $NF); free += $NF } END { printf "%.0f", free * size / 1048576 }')"

# --- 3. Device A -------------------------------------------------------------------------------

say "Device A: create and boot"
new_device A
UDID_A="$NEW_UDID"
note "device A: $UDID_A"
[[ $SHOW == 1 ]] && open -a Simulator
note "booted in $(boot "$UDID_A") s"

# --- 4. Baseline -------------------------------------------------------------------------------

say "4. Baseline: Safari with nothing set opens http://base-$RUN.$DOMAIN/"
launch_safari "$UDID_A" >/dev/null
sleep 3
open_url "$UDID_A" "http://base-$RUN.$DOMAIN/baseline"
BASE_SEEN="$(wait_for_proxy "base-$RUN" 12)"
if [[ -z "$BASE_SEEN" ]]; then
    note "the proxy saw nothing of it: without a setting, Safari does not use our proxy (as expected)"
else
    note "UNEXPECTED: the proxy saw it — this Mac's own proxy settings point at 127.0.0.1:$HTTP_PORT?"
    note "$BASE_SEEN"
fi

# --- 5. Attribution ----------------------------------------------------------------------------

say "5. Attribution: which host process carries device A's connection"
open_url "$UDID_A" "http://127.0.0.1:$PAGE_PORT/attribution-$RUN"
CLIENT="$(page_client)"
ATTRIBUTED=0
if [[ -z "$CLIENT" ]]; then
    note "no connection to the page server was seen (Safari may be on its first-run screen: try --show)"
else
    CLIENT_PID="${CLIENT%% *}"
    CLIENT_PATH="$(ps -o comm= -p "$CLIENT_PID" 2>/dev/null || true)"
    note "connected: pid $CLIENT_PID, ${CLIENT#* }"
    note "binary: $CLIENT_PATH"
    A_PIDS=" $(device_pids "$UDID_A") "
    CLIENT_FILES="$(lsof -p "$CLIENT_PID" 2>/dev/null || true)"
    if [[ "$A_PIDS" == *" $CLIENT_PID "* ]]; then
        ATTRIBUTED=1
        note "it is a process of device A (under the device's launchd_sim): a system network extension can tell this device's flows from another's by the process (audit token → pid → device)"
    elif [[ "$CLIENT_FILES" == *"/Devices/$UDID_A/"* ]]; then
        ATTRIBUTED=1
        note "it has files of device A open (…/Devices/$UDID_A/…): attributable to the device by the process"
    else
        note "NOT attributable to device A by its process tree or open files"
    fi
fi

# --- 6. Environment variables ------------------------------------------------------------------

say "6. Environment variables: Safari relaunched with http_proxy, HTTPS_PROXY, ALL_PROXY, …"
PROXY_URL="http://127.0.0.1:$HTTP_PORT"
ENV_PID="$(launch_safari "$UDID_A" \
    SIMCTL_CHILD_http_proxy="$PROXY_URL" SIMCTL_CHILD_HTTP_PROXY="$PROXY_URL" \
    SIMCTL_CHILD_https_proxy="$PROXY_URL" SIMCTL_CHILD_HTTPS_PROXY="$PROXY_URL" \
    SIMCTL_CHILD_all_proxy="$PROXY_URL" SIMCTL_CHILD_ALL_PROXY="$PROXY_URL")"
note "Safari's pid: ${ENV_PID:-?}"
SAFARI_ENVIRONMENT="$( [[ -n "$ENV_PID" ]] && ps -E -o command= -p "$ENV_PID" 2>/dev/null || true)"
if [[ "$SAFARI_ENVIRONMENT" == *"HTTPS_PROXY=$PROXY_URL"* ]]; then
    note "the variables are in Safari's environment"
else
    note "could not read Safari's environment to confirm the variables (ps -E)"
fi
sleep 3
open_url "$UDID_A" "http://env-$RUN.$DOMAIN/environment"
ENV_SEEN="$(wait_for_proxy "env-$RUN" 15)"
if [[ -n "$ENV_SEEN" ]]; then
    note "THE PROXY SAW IT: Safari's pages follow the environment variables"
    note "$ENV_SEEN"
else
    note "the proxy saw nothing: the environment variables do not reach Safari's networking"
fi

# --- 7. Library injection ----------------------------------------------------------------------

INJECTED=0 INJECTION_LOADED=0
say "7. Library injection: a dylib that gives every WKWebView's data store the proxy"
if (( RUNTIME_MAJOR < 17 )); then
    note "skipped: WKWebsiteDataStore.proxyConfigurations needs iOS 17, this runtime is iOS $RUNTIME_VERSION"
else
    cat >"$WORK/pbspike.m" <<'OBJC'
// Loaded into the simulator's Safari by DYLD_INSERT_LIBRARIES: gives the data store of every
// WKWebView it builds the proxy named by PB_SPIKE_PROXY_HOST/PORT/KIND, at the web view's
// initializer — what ProfileNetworkGuard does for Safari's chrome on the Mac — and says so.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <os/log.h>

static NSString *PBEnv(const char *name) {
    const char *value = getenv(name);
    return value && *value ? [NSString stringWithUTF8String:value] : nil;
}

static void PBTell(NSString *what) {
    os_log(OS_LOG_DEFAULT, "PBSPIKE %{public}@", what);
    NSString *port = PBEnv("PB_SPIKE_PAGE_PORT"), *run = PBEnv("PB_SPIKE_RUN");
    if (!port || !run) return;
    NSString *query = [what stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *address = [NSString stringWithFormat:@"http://127.0.0.1:%@/dylib-%@?pid=%d&what=%@", port, run, getpid(), query];
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:address]] resume];
}

static NSArray *PBProxies(void) {
    NSString *host = PBEnv("PB_SPIKE_PROXY_HOST"), *port = PBEnv("PB_SPIKE_PROXY_PORT"), *kind = PBEnv("PB_SPIKE_PROXY_KIND");
    if (!host || !port) return nil;
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, port.UTF8String);
    nw_proxy_config_t proxy = [kind isEqualToString:@"socks5"] ? nw_proxy_config_create_socksv5(endpoint)
                                                                : nw_proxy_config_create_http_connect(endpoint, nil);
    return proxy ? @[proxy] : nil;
}

static BOOL PBToldFrame, PBToldInitialize;

static void PBGiveProxy(WKWebViewConfiguration *configuration, BOOL *told, const char *where) {
    NSArray *proxies = PBProxies();
    WKWebsiteDataStore *store = configuration.websiteDataStore;
    if (!proxies || !store) return;
    store.proxyConfigurations = proxies;
    if (!*told) {
        *told = YES;
        PBTell([NSString stringWithFormat:@"proxy given to a web view's store at %s", where]);
    }
}

static IMP PBInitWithFrame, PBInitialize;

static id PBInitWithFrameHook(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *configuration) {
    PBGiveProxy(configuration, &PBToldFrame, "initWithFrame:configuration:");
    return ((id (*)(id, SEL, CGRect, WKWebViewConfiguration *))PBInitWithFrame)(self, _cmd, frame, configuration);
}

static void PBInitializeHook(id self, SEL _cmd, WKWebViewConfiguration *configuration) {
    PBGiveProxy(configuration, &PBToldInitialize, "_initializeWithConfiguration:");
    ((void (*)(id, SEL, WKWebViewConfiguration *))PBInitialize)(self, _cmd, configuration);
}

__attribute__((constructor)) static void PBLoaded(void) {
    Class webView = objc_getClass("WKWebView");
    Method frame = class_getInstanceMethod(webView, @selector(initWithFrame:configuration:));
    if (frame) PBInitWithFrame = method_setImplementation(frame, (IMP)PBInitWithFrameHook);
    Method initialize = class_getInstanceMethod(webView, NSSelectorFromString(@"_initializeWithConfiguration:"));
    if (initialize) PBInitialize = method_setImplementation(initialize, (IMP)PBInitializeHook);
    NSString *what = [NSString stringWithFormat:@"loaded in %@ (initWithFrame:configuration: %@, _initializeWithConfiguration: %@)",
                      NSProcessInfo.processInfo.processName, frame ? @"hooked" : @"absent", initialize ? @"hooked" : @"absent"];
    // After the app's run loop is up: no WebKit or networking from inside a library initializer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ PBTell(what); });
}
OBJC
    ARCH="$(uname -m)"
    if ! xcrun --sdk iphonesimulator clang -target "$ARCH-apple-ios17.0-simulator" -dynamiclib -fobjc-arc -fmodules \
            -framework Foundation -framework WebKit -framework Network \
            -o "$WORK/pbspike.dylib" "$WORK/pbspike.m" >"$WORK/clang.log" 2>&1; then
        note "the dylib did not build:"; sed 's/^/      /' "$WORK/clang.log" | head -20
    else
        codesign -s - -f "$WORK/pbspike.dylib" >/dev/null 2>&1 || true
        note "built: $ARCH, for the iOS simulator (ad-hoc signed)"
        INJ_PID="$(launch_safari "$UDID_A" \
            SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$WORK/pbspike.dylib" SIMCTL_CHILD_PB_SPIKE_RUN="$RUN" \
            SIMCTL_CHILD_PB_SPIKE_PAGE_PORT="$PAGE_PORT" SIMCTL_CHILD_PB_SPIKE_PROXY_HOST=127.0.0.1 \
            SIMCTL_CHILD_PB_SPIKE_PROXY_PORT="$HTTP_PORT" SIMCTL_CHILD_PB_SPIKE_PROXY_KIND=http)"
        note "Safari's pid: ${INJ_PID:-?}"
        sleep 4
        open_url "$UDID_A" "http://inj-$RUN.$DOMAIN/injected"
        INJ_SEEN="$(wait_for_proxy "inj-$RUN" 25)"
        if grep -q "dylib-$RUN" "$WORK/pages.jsonl" 2>/dev/null; then
            INJECTION_LOADED=1
            note "the dylib loaded in Safari:"
            grep "dylib-$RUN" "$WORK/pages.jsonl" | python3 -c '
import json, sys, urllib.parse
for line in sys.stdin:
    query = urllib.parse.urlsplit(json.loads(line)["request"].split(" ")[1]).query
    print("      " + urllib.parse.parse_qs(query).get("what", ["?"])[0])'
        else
            # It may have loaded and been kept off the page server (App Transport Security): its log.
            DYLIB_LOG="$(xcrun simctl spawn "$UDID_A" log show --style compact --last 3m --predicate 'eventMessage CONTAINS "PBSPIKE"' 2>/dev/null || true)"
            if [[ "$DYLIB_LOG" == *"PBSPIKE loaded"* ]]; then
                INJECTION_LOADED=1
                note "the dylib loaded in Safari (its log; it could not reach the page server):"
            else
                note "no word from the dylib, in the page server or the device's log: it was not loaded into Safari"
            fi
            printf '%s\n' "$DYLIB_LOG" | grep PBSPIKE | tail -5 | sed 's/^/      /' || true
        fi
        if [[ -n "$INJ_SEEN" ]]; then
            INJECTED=1
            note "THE PROXY SAW IT — Safari's page went through the proxy given by the dylib:"
            printf '%s\n' "$INJ_SEEN" | sed 's/^/      /'
        else
            note "the proxy saw nothing of inj-$RUN"
        fi
    fi
fi

# --- 8. Two devices, two proxies ---------------------------------------------------------------

PER_DEVICE=""
if [[ $INJECTED == 1 && $ONE == 0 ]]; then
    say "8. Device B on the SOCKS5 side of the proxy, device A on the HTTP side, both at once"
    new_device B
    UDID_B="$NEW_UDID"
    note "device B: $UDID_B, booted in $(boot "$UDID_B") s"
    launch_safari "$UDID_B" \
        SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$WORK/pbspike.dylib" SIMCTL_CHILD_PB_SPIKE_RUN="$RUN" \
        SIMCTL_CHILD_PB_SPIKE_PAGE_PORT="$PAGE_PORT" SIMCTL_CHILD_PB_SPIKE_PROXY_HOST=127.0.0.1 \
        SIMCTL_CHILD_PB_SPIKE_PROXY_PORT="$SOCKS_PORT" SIMCTL_CHILD_PB_SPIKE_PROXY_KIND=socks5 >/dev/null
    sleep 4
    open_url "$UDID_A" "http://deva-$RUN.$DOMAIN/device-a"
    open_url "$UDID_B" "http://devb-$RUN.$DOMAIN/device-b"
    SEEN_A="$(wait_for_proxy "deva-$RUN" 25)"
    SEEN_B="$(wait_for_proxy "devb-$RUN" 25)"
    note "device A's page: ${SEEN_A:-nothing}"
    note "device B's page: ${SEEN_B:-nothing}"
    A_RIGHT=0 B_RIGHT=0
    # Each line is "via=<how> target path": every one of A's must be HTTP CONNECT, of B's SOCKS5.
    [[ -n "$SEEN_A" && -z "$(printf '%s\n' "$SEEN_A" | grep -v '^via=connect ' || true)" ]] && A_RIGHT=1
    [[ -n "$SEEN_B" && -z "$(printf '%s\n' "$SEEN_B" | grep -v '^via=socks5 ' || true)" ]] && B_RIGHT=1
    if [[ $A_RIGHT == 1 && $B_RIGHT == 1 ]]; then
        PER_DEVICE=yes
        note "each device's page reached its own proxy only (A: HTTP CONNECT, B: SOCKS5)"
    else
        PER_DEVICE=no
        note "NOT each through its own: A through HTTP only: $A_RIGHT, B through SOCKS5 only: $B_RIGHT"
    fi
fi

# --- 9. Cost, what else the devices reached, the verdict ---------------------------------------

say "9. Memory"
note "device A: $(device_memory "$UDID_A")"
[[ -n "${UDID_B:-}" ]] && note "device B: $(device_memory "$UDID_B")"
memory_after="$(vm_stat | awk '/page size of/ { size = $8 } /Pages (free|inactive|speculative)/ { gsub(/\./, "", $NF); free += $NF } END { printf "%.0f", free * size / 1048576 }')"
TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
note "this Mac: $TOTAL_MB MB; free + inactive went from $memory_before to $memory_after MB while the devices ran (rough: the system frees and caches meanwhile)"
FOOTPRINT_A="$(device_memory "$UDID_A" | sed -n 's/.*footprint \([0-9]*\) MB.*/\1/p' || true)"
if [[ -n "$FOOTPRINT_A" && "$FOOTPRINT_A" -gt 0 ]]; then
    note "estimate at ${FOOTPRINT_A} MB per device (its footprint with Safari and one page), leaving 6 GB to macOS, the app and Simulator.app:"
    for gigabytes in 8 16 24 32; do
        note "    $gigabytes GB Mac: $(( (gigabytes * 1024 - 6144) / FOOTPRINT_A )) device(s)"
    done
fi

say "Processes of the devices with a connection past loopback, right now (a snapshot)"
note "device A:"; device_outside "$UDID_A"
[[ -n "${UDID_B:-}" ]] && { note "device B:"; device_outside "$UDID_B"; }

say "Verdict"
if [[ -n "$BASE_SEEN" ]]; then
    note "baseline (nothing set): the proxy saw the page — this Mac's own proxy setting? (see step 4)"
else
    note "baseline (nothing set): the proxy saw nothing (as expected)"
fi
note "environment variables: $([[ -n "$ENV_SEEN" ]] && echo "Safari's pages went to the proxy" || echo "no effect")"
note "library injection: dylib loaded: $([[ $INJECTION_LOADED == 1 ]] && echo yes || echo no); Safari's pages through the proxy it set: $([[ $INJECTED == 1 ]] && echo yes || echo no)"
note "two devices, each through its own proxy: ${PER_DEVICE:-not run}"
note "a device's connection attributable to the device by its process: $([[ $ATTRIBUTED == 1 ]] && echo yes || echo no)"
echo
if [[ "$PER_DEVICE" == yes ]]; then
    echo "ANSWER: YES — measured: each simulated device's Safari pages go into its own proxy (injection into MobileSafari)."
    echo "ВЫВОД: ДА — измерено: страницы Safari каждого устройства уходят в свой прокси (инъекция в MobileSafari)."
    echo "Not covered by this: the device's other processes (iOS services) — see the snapshot above."
elif [[ $INJECTED == 1 ]]; then
    echo "ANSWER: YES FOR ONE DEVICE — Safari's pages go into the proxy the injected library sets; two devices at once not run (--one)."
    echo "ВЫВОД: ДА ДЛЯ ОДНОГО УСТРОЙСТВА — инъекция работает; два устройства одновременно не проверялись."
elif [[ -n "$ENV_SEEN" ]]; then
    echo "ANSWER: YES — environment variables route Safari's pages into the proxy (per launch, so per device)."
    echo "ВЫВОД: ДА — переменные окружения уводят страницы Safari в прокси (на запуск, то есть на устройство)."
elif [[ $ATTRIBUTED == 1 ]]; then
    echo "ANSWER: NOT WITHOUT A SYSTEM EXTENSION — nothing in the device took a proxy; its connections are attributable to the device, so only a host network extension (transparent proxy) could route them per device. Not measured here."
    echo "ВЫВОД: БЕЗ СИСТЕМНОГО РАСШИРЕНИЯ — НЕТ. Соединения устройства приписываются его процессам: путь только через сетевое расширение на хосте (здесь не проверялся)."
else
    echo "ANSWER: NO — nothing measured here routes one device into its own proxy."
    echo "ВЫВОД: НЕТ — ни один проверенный способ не увёл трафик устройства в его прокси."
fi
echo
echo "Report: $REPORT"
