#!/usr/bin/env bash
# Stage 1 on the owner's real iPhone. Run on the Mac, the iPhone connected by cable, unlocked, on the
# same Wi-Fi as the Mac:
#
#     TEAM=<your Team ID> ios-measure/run_device.sh q1      # then q2, q3
#
# Needs: Xcode with your Apple ID (Xcode › Settings › Accounts; a free Apple ID works, the app then
# lasts 7 days), Developer Mode on the iPhone (Settings › Privacy & Security › Developer Mode), and
# Homebrew (for xcodegen). On the first launch the iPhone asks to trust the developer (Settings ›
# General › VPN & Device Management) and whether the app may find devices on the local network:
# allow both. The script asks for sudo once (lo0 aliases, and a DNS capture of the iPhone's traffic
# through rvictl). Everything goes to ~/lumen-measure-device/<scenario>/ — send that folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="${1:-q1}"
TEAM="${TEAM:?set TEAM to your Team ID (Xcode › Settings › Accounts › your team, or developer.apple.com › Membership)}"
BUNDLE="${BUNDLE_ID:-io.lumenbrowser.measure.$TEAM}"
OUT="$HOME/lumen-measure-device/$SCENARIO"; mkdir -p "$OUT"
# The harness's ports, before anything slow: one left over from a failed run holds them (the owner).
python3 "$HERE/ports_free.py" 28310 28380 28381 28382 28384 28443 3478/udp || exit 1
command -v xcodegen >/dev/null || brew install xcodegen

# The iPhone: devicectl's identifier and the hardware UDID (rvictl). devicectl lists simulators as iOS
# too (the owner, 8 November: the script picked "Profile 18"): device_pick.py takes a real, paired
# iPhone only. Several, or one it would not take: DEVICE=<name or UDID> ios-measure/run_device.sh q1
xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null
PICK="$(python3 "$HERE/device_pick.py" "$OUT/devices.json" "${DEVICE:-}")" || exit 1
read -r CORE UDID TRANSPORT DEVMODE NAME <<<"$PICK"
echo "iPhone: $NAME ($UDID), $TRANSPORT, Developer Mode: $DEVMODE"
if [[ "$DEVMODE" == "disabled" ]]; then
    echo "Developer Mode is off on this iPhone: nothing can be installed until it is on (ios-measure/DEVICE.md, section 0)."
    exit 1
fi
# With Developer Mode on, the iPhone can still be "connected (no DDI)": the developer disk image is
# mounted when devicectl reads the device's details (the owner). Until then it cannot install or
# launch an app.
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
    echo "Run: xcrun devicectl device info details --device $UDID   — then this script again (ios-measure/DEVICE.md, section 0)."
    exit 1
fi
echo "the iPhone can install and launch apps"

cd "$HERE/device"
xcodegen generate --quiet
xcodebuild -project LumenMeasure.xcodeproj -scheme LumenMeasure -configuration Debug -destination "generic/platform=iOS" \
    -derivedDataPath "$OUT/build" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build \
    | tail -3
APP="$(find "$OUT/build/Build/Products" -name LumenMeasure.app -maxdepth 2 | head -1)"
# The app is the one launched below: its bundle and its signature both say $BUNDLE (the owner's run:
# Info.plist said io.lumenbrowser.measure, the signature …measure.<team>).
python3 "$HERE/check_app.py" "$APP" "$BUNDLE" || exit 1
xcrun devicectl device install app --device "$CORE" "$APP" >/dev/null && echo "installed $BUNDLE"

LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
echo "this Mac on the network: $LAN"
for a in 127.0.0.2 127.0.0.3; do sudo ifconfig lo0 alias "$a" up; done
# The iPhone's own packets, DNS included, through the Remote Virtual Interface.
CAPTURE=""
if [[ "$UDID" != "-" ]] && sudo rvictl -s "$UDID" >/dev/null 2>&1; then CAPTURE="rvi0"; echo "capturing the iPhone's DNS on rvi0"; fi
cat > "$OUT/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = lumentest
[ext]
subjectAltName = DNS:*.lumentest, DNS:lumentest
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 3 -config "$OUT/cert.cnf" >/dev/null 2>&1

python3 "$HERE/host/harness.py" --scenario "$SCENARIO" --listen 0.0.0.0 --proxy-host "$LAN" --lan-ip "$LAN" \
    --bind-a 127.0.0.2 --bind-b 127.0.0.3 --cert "$OUT/cert.pem" --key "$OUT/key.pem" --capture "$CAPTURE" \
    --static-dir "$HERE/host/static" --out "$OUT" --wait-app 300 2>&1 | tee "$OUT/harness.txt" &
HARNESS=$!
sleep 2
# The harness's address goes in the environment (the driver reads LUMEN_CONTROL): an argument after
# the bundle id is parsed by devicectl itself — "-control" was read as "-t", its timeout (the owner).
xcrun devicectl device process launch --device "$CORE" --terminate-existing \
    --environment-variables "{\"LUMEN_CONTROL\": \"http://$LAN:28310\"}" "$BUNDLE" >/dev/null \
    || echo "devicectl could not launch it: tap Lumen Measure on the iPhone (it keeps the Mac's address from its last launch)."
wait $HARNESS || true
[[ "$CAPTURE" == "rvi0" ]] && sudo rvictl -x "$UDID" >/dev/null 2>&1 || true
echo; echo "Done. Send the folder $OUT (it holds no secret: test names, test passwords, the iPhone's model and iOS version)."
