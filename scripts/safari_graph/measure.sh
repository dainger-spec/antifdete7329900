#!/usr/bin/env bash
# SAFARI_GRAPH spike — compile the load probe, sign it under each hardened-runtime exception in
# turn, and run it. Used by CI (macos-26, macos-15) and by the owner's manual check.
#
#   scripts/safari_graph/measure.sh [OUT_DIR]
#
# OUT_DIR (default build/safari-graph) receives probe.log and probe-<variant>.json. Exit 0 whenever
# the probe measured: a variant that crashes or times out is a result, not a failure of the
# measurement. GRAPH_STRICT=1 exits nonzero when the probe does not compile or cannot be signed.
# Written for the bash 3.2 that macOS ships (no empty arrays under `set -u`, no `timeout`).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="${1:-$ROOT/build/safari-graph}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/probe.log"
: > "$LOG"

log() { echo "$@" | tee -a "$LOG"; }
fail_setup() {
    log "ERROR: $1"
    if [ "${GRAPH_STRICT:-0}" = "1" ]; then exit 1; fi
    exit 0
}

# No GNU `timeout` on macOS; perl is always there. A child killed by a signal exits 128+signal, as a
# shell reports it, so a crash inside Safari.framework shows as e.g. 134 (SIGABRT), not as 0.
run_with_timeout() {
    local seconds="$1"; shift
    perl -e 'my $t = shift; my $pid = fork; if ($pid == 0) { exec @ARGV or exit 127 }
             local $SIG{ALRM} = sub { kill "KILL", $pid; waitpid $pid, 0; exit 124 };
             alarm $t; waitpid $pid, 0;
             exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8))' "$seconds" "$@"
}

log "== safari_graph probe =="
log "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "system: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
log "clang: $(clang --version 2>/dev/null | head -1)"
log "SIP: $(csrutil status 2>/dev/null)"

PROBE_BIN="$OUT_DIR/probe"
log "-- compiling probe.m --"
clang -fobjc-arc -mmacosx-version-min=14.0 -o "$PROBE_BIN" "$HERE/probe.m" \
    -framework Foundation -framework AppKit -framework Security 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" = "0" ] || fail_setup "probe.m did not compile"
log "compiled: $PROBE_BIN"

# Each variant adds exactly one hardened-runtime exception to the baseline (plus `all` of them
# together), so the matrix isolates what each one changes. `all` also tries to bring up a window.
for variant in base libval dyld jit all; do
    ent="$HERE/entitlements/$variant.entitlements"
    bin="$OUT_DIR/probe-$variant"
    cp "$PROBE_BIN" "$bin"
    log ""
    log "=================== variant: $variant ==================="
    codesign --force --options runtime --entitlements "$ent" --sign - "$bin" 2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" != "0" ]; then
        log "ERROR: could not sign variant $variant"
        [ "${GRAPH_STRICT:-0}" = "1" ] && exit 1
        continue
    fi
    if [ "$variant" = "all" ]; then
        GRAPH_VARIANT="$variant" run_with_timeout 90 "$bin" --json "$OUT_DIR/probe-$variant.json" --try-window 2>&1 | tee -a "$LOG"
        code="${PIPESTATUS[0]}"
    else
        GRAPH_VARIANT="$variant" run_with_timeout 90 "$bin" --json "$OUT_DIR/probe-$variant.json" 2>&1 | tee -a "$LOG"
        code="${PIPESTATUS[0]}"
    fi
    log "variant $variant exit: $code"
done

log ""
log "== summary: Safari.framework loaded per variant =="
grep -E '^GRAPH (variant|safari_framework_loaded|safari_shared_loaded|window_attempt)=' "$LOG" | tee "$OUT_DIR/summary.txt" || true
log "== probe matrix complete =="
exit 0
