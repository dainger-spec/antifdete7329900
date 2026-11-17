#!/bin/bash
# Typing into Safari's address bar in a profile's own process (`Lumen --address-bar-check`,
# AddressBarCheck): one profile per search engine, held to the self-test proxy, "google" typed one
# key press at a time; the field must hold it, with no exception and no notice. Then a real Return:
# the search must go to the profile's engine, as the proxy sees it (Google's profile also goes to
# example.com and to the completion list's first row). And Safari's stores in each profile's home,
# before and after. A customer's address bar put up "not available in a profile" at every key
# (0.1.17 or earlier); another's, on macOS 27.2.1, at Return.
#
#   scripts/address_bar_check.sh <Lumen.app> [out folder] [engines, e.g. google,bing]
#
# Exit 0 when it passed, 1 when not; its lines are in <out>/check.txt, the proxy's in <out>/proxy.txt.
# TITLE names the notice on the run's page. QUICK=1 types "google" once, in one launch, per engine.
# FS_TRACE=1 traces the profiles' file-system calls meanwhile (fs_usage, sudo) into <out>/fs.txt and
# says where Safari's code looked for its stores and what it was refused (scripts/safari_stores_trace.py).
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
# AX_POLLER=1: an accessibility client reads the focused field all along, as the apps that act on
# every key press through the accessibility API do (scripts/ax_poller.swift); its lines go to
# <out>/ax-poller.txt.
POLLER=""
if [[ "${AX_POLLER:-}" == "1" ]]; then
  if swiftc -O "$HERE/ax_poller.swift" -o "$OUT/ax_poller" > "$OUT/ax-poller-build.txt" 2>&1; then
    "$OUT/ax_poller" 900 > "$OUT/ax-poller.txt" 2>&1 &
    POLLER=$!
    trap 'kill "$PROXY" 2>/dev/null; [[ -n "$POLLER" ]] && kill "$POLLER" 2>/dev/null' EXIT
  else
    echo "ADDRESS-BAR INFO the accessibility client did not build (see $OUT/ax-poller-build.txt)"
  fi
fi
TRACE=""
if [[ "${FS_TRACE:-}" == "1" ]]; then
  if sudo -n true 2>/dev/null; then
    sudo -n fs_usage -w -f filesys LumenProfile > "$OUT/fs.txt" 2>&1 &
    TRACE=$!
    sleep 2
    trap 'kill "$PROXY" 2>/dev/null; [[ -n "$POLLER" ]] && kill "$POLLER" 2>/dev/null; sudo -n pkill -INT -f "fs_usage -w" 2>/dev/null' EXIT
  else
    echo "ADDRESS-BAR INFO no sudo: the profiles' file-system calls are not traced"
  fi
fi
args=(--address-bar-check)
[[ -n "$ENGINES" ]] && args+=(--engines "$ENGINES")
[[ "${QUICK:-}" == "1" ]] && args+=(--quick)
PRIVACYBROWSER_LANG="${PRIVACYBROWSER_LANG:-en}" PB_SELFTEST_HTTP_PROXY_PORT="$PORT" "$APP/Contents/MacOS/Lumen" "${args[@]}" \
  2> "$OUT/stderr.txt" | tee "$OUT/check.txt"
status=${PIPESTATUS[0]}
if [[ -n "$TRACE" ]]; then
  sudo -n pkill -INT -f "fs_usage -w" 2>/dev/null
  sleep 2
  python3 -I "$HERE/safari_stores_trace.py" "$OUT/fs.txt" --real-home "$HOME" | tee "$OUT/stores-trace.txt"
fi
if [[ -n "$POLLER" ]]; then
  kill "$POLLER" 2>/dev/null
  grep -E "trusted|focused element|done" "$OUT/ax-poller.txt" | head -12 | sed 's/^/ADDRESS-BAR INFO /'
  tail -n 1 "$OUT/ax-poller.txt" | sed 's/^/ADDRESS-BAR INFO /'
fi
NOTICE="${TITLE:-}"
[[ -n "$NOTICE" ]] || NOTICE="Typing into Safari's address bar"
grep -E '^ADDRESS-BAR (PASS|FAIL|THROWN|AX-THREW|COMMIT-THREW|RESCUED|STORES SUMMARY)' "$OUT/check.txt" | cut -c1-900 | sed "s/^/::notice title=$NOTICE::/" || true
exit "$status"
