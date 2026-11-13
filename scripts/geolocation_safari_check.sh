#!/bin/bash
# A profile with a fixed place, run in its own process, in Safari's window
# (`Lumen --geolocation-safari-check`, GeolocationSafariCheck): the self-test proxy serves a secure
# loopback page, the profile is started without a window as the editor's Run starts one, and a
# scenario in Safari's window must get the profile's place from navigator.geolocation — from the
# engine itself (NativeGeolocation), as the page script leaves geolocation alone there — with the
# permission 'prompt' before the page asks and 'granted' after.
#
#   scripts/geolocation_safari_check.sh <Lumen.app> [out folder]
#
# Exit 0 when it passed, 1 when not; its lines are in <out>/check.txt, the proxy's in <out>/proxy.txt.
# TITLE names the notice on the run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?the app, e.g. build/unsandboxed/Lumen.app}"
OUT="${2:-build/geolocation-safari}"
PORT="${PB_GEOLOCATION_SAFARI_PORT:-18302}"
mkdir -p "$OUT"
python3 "$HERE/selftest_proxy.py" --http "$PORT" --socks "$((PORT + 1))" > "$OUT/proxy.txt" 2>&1 &
PROXY=$!
trap 'kill "$PROXY" 2>/dev/null' EXIT
for attempt in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" && break; sleep 0.5; done
if ! nc -z 127.0.0.1 "$PORT"; then
  echo "GEOLOCATION-SAFARI FAIL the self-test proxy did not start (see $OUT/proxy.txt)" | tee "$OUT/check.txt"
  exit 1
fi
PRIVACYBROWSER_LANG=en PB_SELFTEST_HTTP_PROXY_PORT="$PORT" "$APP/Contents/MacOS/Lumen" --geolocation-safari-check \
  2> "$OUT/stderr.txt" | tee "$OUT/check.txt"
status=${PIPESTATUS[0]}
NOTICE="${TITLE:-}"
[[ -n "$NOTICE" ]] || NOTICE="Geolocation from the engine in Safari's window"
grep -E '^GEOLOCATION-SAFARI (PASS|FAIL)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
exit "$status"
