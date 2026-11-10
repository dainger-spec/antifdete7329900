#!/bin/bash
# A scenario's run in a profile's own process, in Safari's window (`Lumen --scenario-safari-check`,
# ScenarioSafariCheck): the self-test proxy serves the automation form, a profile is started
# without a window as the scenario editor's Run starts one, and the run must finish in a window of
# Safari's with its click on the button it aimed at — trusted, inside the button's box, as the
# page itself recorded it — and its typing in the field. The owner, 10 November: a run in a window
# of the app's own is not Safari.
#
#   scripts/scenario_safari_check.sh <Lumen.app> [out folder]
#
# Exit 0 when it passed, 1 when not; its lines are in <out>/check.txt, the proxy's in <out>/proxy.txt.
# TITLE names the notice on the run's page.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?the app, e.g. build/unsandboxed/Lumen.app}"
OUT="${2:-build/scenario-safari}"
PORT="${PB_SCENARIO_SAFARI_PORT:-18290}"
mkdir -p "$OUT"
python3 "$HERE/selftest_proxy.py" --http "$PORT" --socks "$((PORT + 1))" > "$OUT/proxy.txt" 2>&1 &
PROXY=$!
trap 'kill "$PROXY" 2>/dev/null' EXIT
for attempt in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" && break; sleep 0.5; done
if ! nc -z 127.0.0.1 "$PORT"; then
  echo "SCENARIO-SAFARI FAIL the self-test proxy did not start (see $OUT/proxy.txt)" | tee "$OUT/check.txt"
  exit 1
fi
PRIVACYBROWSER_LANG=en PB_SELFTEST_HTTP_PROXY_PORT="$PORT" "$APP/Contents/MacOS/Lumen" --scenario-safari-check \
  2> "$OUT/stderr.txt" | tee "$OUT/check.txt"
status=${PIPESTATUS[0]}
NOTICE="${TITLE:-}"
[[ -n "$NOTICE" ]] || NOTICE="A scenario in Safari's window"
grep -E '^SCENARIO-SAFARI (PASS|FAIL)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
exit "$status"
