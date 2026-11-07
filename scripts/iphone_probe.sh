#!/usr/bin/env bash
# The fingerprint probe on a real iPhone, for the comparison with the simulator and our mobile
# profile (claude/measure-ios-sim). Run it on a Mac on the same Wi-Fi as the iPhone:
#
#     scripts/iphone_probe.sh
#
# It serves one page on this Mac's address in the local network (port 28199), prints the address,
# and waits. Open that address in Safari on the iPhone (not in a private tab, no content blockers).
# The page runs the same probe (Resources/fingerprint_probe.js) and sends its result back here,
# into iphone-probe/probe-iphone.json — that file is what to send. Ctrl-C stops the server.
# The page asks for nothing and stores nothing on the iPhone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${PB_IPHONE_PROBE_PORT:-28199}"
OUT="$PWD/iphone-probe"
ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[[ -n "$ADDRESS" ]] || { echo "No Wi-Fi or Ethernet address on this Mac: connect it to the iPhone's network." >&2; exit 1; }
mkdir -p "$OUT"
echo "On the iPhone, open in Safari:   http://$ADDRESS:$PORT/probe?name=probe-iphone"
echo "When the page says \"Sent.\", send this file: $OUT/probe-iphone.json"
echo "(macOS may ask whether python3 may accept incoming connections: allow it.)"
exec python3 "$HERE/sim_pages.py" --host 0.0.0.0 --port "$PORT" --reports "$OUT"
