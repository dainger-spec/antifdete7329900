#!/bin/bash
# Typing into Safari's address bar in a profile's own process (`Lumen --address-bar-check`,
# AddressBarCheck): one profile per search engine, held to the self-test proxy, "google" typed one
# key press at a time; the field must hold it, with no exception and no notice. A customer's
# address bar put up "not available in a profile" at every key (0.1.17 or earlier).
#
#   scripts/address_bar_check.sh <Lumen.app> [out folder] [engines, e.g. google,bing]
#
# Exit 0 when it passed, 1 when not; its lines are in <out>/check.txt, the proxy's in <out>/proxy.txt.
# TITLE names the notice on the run's page.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?the app, e.g. build/unsandboxed/Lumen.app}"
OUT="${2:-build/address-bar}"
ENGINES="${3:-}"
PORT="${PB_ADDRESS_BAR_PORT:-18300}"
mkdir -p "$OUT"
python3 "$HERE/selftest_proxy.py" --http "$PORT" --socks "$((PORT + 1))" > "$OUT/proxy.txt" 2>&1 &
PROXY=$!
trap 'kill "$PROXY" 2>/dev/null' EXIT
for attempt in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" && break; sleep 0.5; done
if ! nc -z 127.0.0.1 "$PORT"; then
  echo "ADDRESS-BAR FAIL the self-test proxy did not start (see $OUT/proxy.txt)" | tee "$OUT/check.txt"
  exit 1
fi
args=(--address-bar-check)
[[ -n "$ENGINES" ]] && args+=(--engines "$ENGINES")
PRIVACYBROWSER_LANG="${PRIVACYBROWSER_LANG:-en}" PB_SELFTEST_HTTP_PROXY_PORT="$PORT" "$APP/Contents/MacOS/Lumen" "${args[@]}" \
  2> "$OUT/stderr.txt" | tee "$OUT/check.txt"
status=${PIPESTATUS[0]}
NOTICE="${TITLE:-}"
[[ -n "$NOTICE" ]] || NOTICE="Typing into Safari's address bar"
grep -E '^ADDRESS-BAR (PASS|FAIL|THROWN)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
exit "$status"
