#!/bin/bash
# A team's Selenium script against a profile (docs/AUTOMATION.md, "WebDriver"): `Lumen
# --webdriver-serve` (WebDriverCheck) listens over a temporary vault and prints a profile's
# WebDriver address; scripts/webdriver_check.py drives it — a session starts the profile in a
# process of its own with Safari's window, opens the self-test proxy's form, finds the field,
# types, clicks the button, reads the text, and ends the session. With Selenium when it can be
# installed (a virtual environment under the out folder), else the same protocol by hand; the
# last line says which.
#
#   scripts/webdriver_check.sh <Lumen.app> [out folder]
#
# Exit 0 when it passed, 1 when not; its lines are in <out>/check.txt, the app's in <out>/serve.txt,
# the proxy's in <out>/proxy.txt. TITLE names the notice on the run's page.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?the app, e.g. build/unsandboxed/Lumen.app}"
OUT="${2:-build/webdriver}"
PORT="${PB_WEBDRIVER_PORT:-18310}"
mkdir -p "$OUT"
NOTICE="${TITLE:-}"
[[ -n "$NOTICE" ]] || NOTICE="Selenium against a profile"
python3 "$HERE/selftest_proxy.py" --http "$PORT" --socks "$((PORT + 1))" > "$OUT/proxy.txt" 2>&1 &
PROXY=$!
SERVE=""
trap 'kill "$PROXY" $SERVE 2>/dev/null' EXIT
for attempt in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" && break; sleep 0.5; done
fail() {
  echo "WEBDRIVER FAIL $1" | tee -a "$OUT/check.txt"
  grep -E '^WEBDRIVER (PASS|FAIL)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
  exit 1
}
: > "$OUT/check.txt"
nc -z 127.0.0.1 "$PORT" || fail "the self-test proxy did not start (see $OUT/proxy.txt)"
PRIVACYBROWSER_LANG=en PB_SELFTEST_HTTP_PROXY_PORT="$PORT" "$APP/Contents/MacOS/Lumen" --webdriver-serve \
  > "$OUT/serve.txt" 2> "$OUT/stderr.txt" &
SERVE=$!
ADDRESS=""
for attempt in $(seq 1 120); do
  ADDRESS="$(sed -n 's/^WEBDRIVER ADDRESS //p' "$OUT/serve.txt" | head -1)"
  [[ -n "$ADDRESS" ]] && break
  kill -0 "$SERVE" 2>/dev/null || break
  sleep 0.5
done
grep -E '^WEBDRIVER (INFO|FAIL)' "$OUT/serve.txt" >> "$OUT/check.txt" || true
[[ -n "$ADDRESS" ]] || fail "the app gave no WebDriver address (see $OUT/serve.txt)"
# Selenium, where it can be had: its own environment, nothing installed into the system's Python.
PYTHON=python3
if python3 -m venv "$OUT/venv" > "$OUT/pip.txt" 2>&1 && "$OUT/venv/bin/pip" install --quiet selenium >> "$OUT/pip.txt" 2>&1; then
  PYTHON="$OUT/venv/bin/python3"
fi
"$PYTHON" "$HERE/webdriver_check.py" "$ADDRESS" "http://automation.selftest.invalid/pb-automation/form" 2>> "$OUT/stderr.txt" | tee -a "$OUT/check.txt"
status=${PIPESTATUS[0]}
grep -E '^WEBDRIVER INFO' "$OUT/serve.txt" | tail -3 >> "$OUT/check.txt" || true
grep -E '^WEBDRIVER (PASS|FAIL)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
exit "$status"
