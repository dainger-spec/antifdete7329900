#!/usr/bin/env bash
# Lumen for iPhone on the owner's real iPhone (q4, the network switch): builds the app (Debug, which
# has the network probe), installs it and starts it, and records everything the iPhone sends while
# the probe runs (rvictl): afterwards it says whether any of it went to the echo service around the
# proxy. ios/DEVICE.md says what to do on the iPhone meanwhile.
#
#     TEAM=<your Team ID> ios/scripts/run-device.sh
#
# Before anything slow it checks what the owner's runs of 8 November tripped on: the iPhone picked
# (never a simulator), Developer Mode and the developer disk image, and the recording — it must see
# the iPhone's packets, and the iPhone's VPN must be off (the first run had a fake-IP VPN in the chain,
# the second recorded 0 packets and still read as passed). Without a cable: NO_CAPTURE=1, and the
# probe's own verdict is the only one. Needs Xcode with your Apple ID, Developer Mode on the iPhone,
# Homebrew (for xcodegen). Everything goes to ~/lumen-device/q4/ — send that folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
S="$HERE/scripts"
TEAM="${TEAM:?set TEAM to your Team ID (Xcode › Settings › Accounts › your team)}"
BUNDLE="${BUNDLE_ID:-io.lumenbrowser.ios.$TEAM}"
OUT="$HOME/lumen-device/q4"; mkdir -p "$OUT"
command -v xcodegen >/dev/null || brew install xcodegen

# The iPhone: a real, paired one (devicectl lists simulators as iOS too). Several: DEVICE=<name or UDID>.
xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null
PICK="$(python3 "$S/device_pick.py" "$OUT/devices.json" "${DEVICE:-}")" || exit 1
read -r CORE UDID TRANSPORT DEVMODE NAME <<<"$PICK"
echo "iPhone: $NAME ($UDID), $TRANSPORT, Developer Mode: $DEVMODE"
if [[ "$DEVMODE" == "disabled" ]]; then
    echo "Developer Mode is off on this iPhone: nothing can be installed until it is on (ios-measure/DEVICE.md, section 0)."
    exit 1
fi
# The developer disk image is mounted when devicectl reads the device's details; until then the
# iPhone cannot install or launch an app ("connected (no DDI)").
ready=""
for attempt in 1 2 3 4 5 6; do
    xcrun devicectl device info details --device "$CORE" --json-output "$OUT/details.json" >/dev/null 2>&1 || true
    ready="$(python3 - "$OUT/details.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))["result"]
except Exception:
    sys.exit()
names = {c.get("name", "") for c in d.get("capabilities", [])}
print("yes" if {"Install Application", "Launch Application"} <= names else "no: " + ", ".join(sorted(names)[:12]))
PY
)"
    [[ "$ready" == "yes" ]] && break
    sleep 5
done
if [[ "$ready" != "yes" ]]; then
    echo "The iPhone cannot install or launch apps yet (developer disk image not mounted): ${ready:-no details}."
    echo "Run: xcrun devicectl device info details --device $UDID   — then this script again."
    exit 1
fi

# The recording, before the build: it must see the iPhone, and no VPN.
CAPTURE=""
if [[ "${NO_CAPTURE:-}" == "1" ]]; then
    echo "NO_CAPTURE=1: nothing is recorded on the Mac — the probe's own verdict is the only one"
elif [[ "$UDID" == "-" ]]; then
    echo "devicectl gives no hardware UDID for this iPhone, rvictl cannot record it: connect it by cable (or NO_CAPTURE=1)."
    exit 1
else
    echo "sudo: rvictl and tcpdump record the iPhone's packets"
    CAPTURE="$(sudo python3 "$S/capture_look.py" start "$UDID")" || exit 1
    echo "recording on $CAPTURE. A first look, 30 s: unlock the iPhone and open any page in Safari now."
    if ! sudo python3 "$S/capture_look.py" look "$CAPTURE" 30; then
        sudo rvictl -x "$UDID" >/dev/null 2>&1 || true
        exit 1
    fi
fi

(cd "$HERE" && xcodegen generate --quiet)
xcodebuild -project "$HERE/Lumen.xcodeproj" -scheme Lumen -configuration Debug -destination "generic/platform=iOS" \
    -derivedDataPath "$OUT/build" -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build | tail -3
APP="$(find "$OUT/build/Build/Products" -maxdepth 2 -name Lumen.app -type d | head -1)"
python3 "$S/check_app.py" "$APP" "$BUNDLE" || exit 1
xcrun devicectl device install app --device "$CORE" "$APP" >/dev/null && echo "installed $BUNDLE"

# Headers only (300 bytes a packet: DNS and the connections' first packets are what is judged), and
# the recording stays on this Mac — capture-summary.txt is what to send.
TCPDUMP=""
if [[ -n "$CAPTURE" ]]; then
    sudo tcpdump -i "$CAPTURE" -n -s 300 -w "$OUT/iphone.pcap" 2>"$OUT/tcpdump.txt" &
    TCPDUMP=$!
fi
xcrun devicectl device process launch --device "$CORE" --terminate-existing "$BUNDLE" >/dev/null \
    || echo "devicectl could not start it: tap Lumen on the iPhone."
echo
echo "On the iPhone: ios/DEVICE.md, q4 (the control run, then the run through your proxy)."
read -r -p "When both runs are done and the logs sent, press Enter here. " _

if [[ -n "$TCPDUMP" ]]; then
    sudo pkill -INT -f "tcpdump -i $CAPTURE -n -s 300" 2>/dev/null || true
    wait "$TCPDUMP" 2>/dev/null || true
    sudo rvictl -x "$UDID" >/dev/null 2>&1 || true
    cat "$OUT/tcpdump.txt"
    # Around the proxy, to the echo service the probe's page asks (ipify): a DNS question for its
    # names, or a connection to its addresses. The app's own direct questions to icanhazip are the
    # control: a recording that does not see them gives no verdict (NOT MEASURED), never "none".
    set +e
    python3 "$S/capture_look.py" summary "$OUT/iphone.pcap" | tee "$OUT/capture-summary.txt"
    set -e
fi
echo; echo "Done. Send the folder $OUT without iphone.pcap (all the iPhone's traffic of the run: keep it here, it is asked"
echo "for only if capture-summary.txt needs a second look), and the probe's two logs (no password in them)."
