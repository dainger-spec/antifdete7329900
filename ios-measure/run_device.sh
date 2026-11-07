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
command -v xcodegen >/dev/null || brew install xcodegen

# The connected iPhone: CoreDevice identifier (devicectl) and hardware UDID (rvictl).
xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null
read -r CORE UDID NAME < <(python3 - "$OUT/devices.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(d["identifier"], hw.get("udid", ""), d.get("deviceProperties", {}).get("name", "iPhone").replace(" ", "_")); break
PY
)
[[ -n "${CORE:-}" ]] || { echo "No iPhone found by devicectl: connect it, unlock it, trust this Mac."; exit 1; }
echo "iPhone: $NAME ($UDID)"

cd "$HERE/device"
xcodegen generate --quiet
xcodebuild -project LumenMeasure.xcodeproj -scheme LumenMeasure -configuration Debug -destination "generic/platform=iOS" \
    -derivedDataPath "$OUT/build" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build \
    | tail -3
APP="$(find "$OUT/build/Build/Products" -name LumenMeasure.app -maxdepth 2 | head -1)"
xcrun devicectl device install app --device "$CORE" "$APP" >/dev/null && echo "installed $BUNDLE"

LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
echo "this Mac on the network: $LAN"
for a in 127.0.0.2 127.0.0.3; do sudo ifconfig lo0 alias "$a" up; done
# The iPhone's own packets, DNS included, through the Remote Virtual Interface.
CAPTURE=""
if [[ -n "$UDID" ]] && sudo rvictl -s "$UDID" >/dev/null 2>&1; then CAPTURE="rvi0"; echo "capturing the iPhone's DNS on rvi0"; fi
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
xcrun devicectl device process launch --device "$CORE" --terminate-existing "$BUNDLE" -control "http://$LAN:28310" >/dev/null \
    || echo "devicectl could not launch it: tap Lumen Measure on the iPhone (it keeps the Mac's address from its last launch)."
wait $HARNESS || true
[[ "$CAPTURE" == "rvi0" ]] && sudo rvictl -x "$UDID" >/dev/null 2>&1 || true
echo; echo "Done. Send the folder $OUT (it holds no secret: test names, test passwords, the iPhone's model and iOS version)."
