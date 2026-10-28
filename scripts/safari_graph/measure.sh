#!/usr/bin/env bash
# SAFARI_GRAPH spike — compile the load probe and run it under each hardened-runtime exception in turn,
# with and without the step Safari.app itself takes to load its frameworks. Used by CI (macos-26,
# macos-15) and by the owner's manual check (manual_check.sh).
#
#   scripts/safari_graph/measure.sh [OUT_DIR]
#
# What it measures (docs/SAFARI_GRAPH_SPIKE.md):
#   1. each entitlement variant (base: none; libval, dyld, jit: one exception each; all) plain;
#   2. the same with DYLD_VERSIONED_FRAMEWORK_PATH pointing at Safari's staged frameworks in the App
#      cryptex, which is how Safari.app makes dyld take the Safari-version copies of WebKit and of its
#      private frameworks instead of the base system's;
#   3. that path embedded in the probe itself (LC_DYLD_ENVIRONMENT, as Safari's executable may carry it);
#   4. in the first configuration where Safari.framework loads: Safari's window controller, and Safari's
#      own entry point, each in a process of its own, with a throwaway home folder.
#
# OUT_DIR (default build/safari-graph) receives probe.log, run-<label>.log, probe-<label>.json and
# summary.txt. Exit 0 whenever it measured: a run that crashes or times out is a result. GRAPH_STRICT=1
# exits nonzero when the probe does not compile or cannot be signed. Written for the bash 3.2 macOS
# ships (no empty arrays or bare "$@" under set -u, no `timeout`).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="${1:-$ROOT/build/safari-graph}"
STAGED=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/probe.log"
: > "$LOG"

log() { echo "$@" | tee -a "$LOG"; }
setup_failed() {
    log "ERROR: $1"
    if [ "${GRAPH_STRICT:-0}" = "1" ]; then exit 1; fi
    exit 0
}

# No GNU `timeout` on macOS; perl is always there. A child killed by a signal exits 128+signal, as a
# shell reports it (a crash inside Safari.framework shows as 134 or 139, not as 0). GRAPH_DYLD_VFP is
# turned into DYLD_VERSIONED_FRAMEWORK_PATH by perl just before exec: with SIP on, dyld strips DYLD_*
# from the environment of SIP-protected programs such as perl itself, so it cannot be passed through.
run_with_timeout() {
    local seconds="$1"; shift
    perl -e 'my $t = shift;
             $ENV{DYLD_VERSIONED_FRAMEWORK_PATH} = $ENV{GRAPH_DYLD_VFP} if defined $ENV{GRAPH_DYLD_VFP} && length $ENV{GRAPH_DYLD_VFP};
             delete $ENV{GRAPH_DYLD_VFP};
             my $pid = fork; if ($pid == 0) { exec @ARGV or exit 127 }
             local $SIG{ALRM} = sub { kill "KILL", $pid; waitpid $pid, 0; exit 124 };
             alarm $t; waitpid $pid, 0;
             exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8))' "$seconds" "$@"
}

# run_probe LABEL BINARY ENV(plain|env) [probe arguments…]: one probe process, its output in
# run-LABEL.log and in probe.log.
run_probe() {
    local label="$1" bin="$2" mode="$3"; shift 3
    local runlog="$OUT_DIR/run-$label.log" vfp="" code
    [ "$mode" = "env" ] && vfp="$STAGED"
    log ""
    log "=================== run: $label ==================="
    GRAPH_DYLD_VFP="$vfp" GRAPH_VARIANT="$label" \
        run_with_timeout 90 "$bin" --json "$OUT_DIR/probe-$label.json" ${1+"$@"} > "$runlog" 2>&1
    code=$?
    cat "$runlog" | tee -a "$LOG"
    log "run $label exit: $code"
}

sign() {  # sign SOURCE DEST ENTITLEMENTS_NAME
    cp "$1" "$2"
    codesign --force --options runtime --entitlements "$HERE/entitlements/$3.entitlements" --sign - "$2" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}

log "== safari_graph probe =="
log "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "system: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
log "clang: $(clang --version 2>/dev/null | head -1)"
log "SIP: $(csrutil status 2>/dev/null)"
log "staged frameworks: $STAGED ($( [ -d "$STAGED" ] && echo present || echo absent ))"

compile() {  # compile OUTPUT [extra linker flags…]
    local out="$1"; shift
    clang -fobjc-arc -mmacosx-version-min=14.0 -o "$out" "$HERE/probe.m" \
        -framework Foundation -framework AppKit -framework Security ${1+"$@"} 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}
log "-- compiling probe.m --"
compile "$OUT_DIR/probe" || setup_failed "probe.m did not compile"
log "-- compiling probe.m with DYLD_VERSIONED_FRAMEWORK_PATH embedded (LC_DYLD_ENVIRONMENT) --"
compile "$OUT_DIR/probe-linked" "-Wl,-dyld_env,DYLD_VERSIONED_FRAMEWORK_PATH=$STAGED" \
    || setup_failed "probe.m did not compile with -dyld_env"
otool -l "$OUT_DIR/probe-linked" | grep -A3 LC_DYLD_ENVIRONMENT | tee -a "$LOG"

# The matrix. Each label's configuration is kept so the UI attempts can repeat the first that loads.
CONFIGS=""
for variant in base libval dyld jit all; do
    sign "$OUT_DIR/probe" "$OUT_DIR/probe-$variant" "$variant" || setup_failed "could not sign $variant"
    run_probe "$variant" "$OUT_DIR/probe-$variant" plain
    run_probe "$variant+env" "$OUT_DIR/probe-$variant" env
    CONFIGS="$CONFIGS $variant|$OUT_DIR/probe-$variant|plain $variant+env|$OUT_DIR/probe-$variant|env"
done
for variant in base dyld; do
    sign "$OUT_DIR/probe-linked" "$OUT_DIR/probe-linked-$variant" "$variant" || setup_failed "could not sign linked $variant"
    run_probe "linked-$variant" "$OUT_DIR/probe-linked-$variant" plain
    CONFIGS="$CONFIGS linked-$variant|$OUT_DIR/probe-linked-$variant|plain"
done

# The UI, in the first configuration where Safari.framework loaded.
loaded=""
for config in $CONFIGS; do
    label="${config%%|*}"
    if grep -q '^GRAPH safari_framework_loaded=yes' "$OUT_DIR/run-$label.log" 2>/dev/null; then loaded="$config"; break; fi
done
log ""
if [ "${GRAPH_UI:-1}" != "1" ]; then
    log "== UI attempts off (GRAPH_UI=0); Safari.framework loaded in: ${loaded%%|*} =="
elif [ -z "$loaded" ]; then
    log "== UI attempts skipped: Safari.framework loaded in no configuration =="
else
    label="${loaded%%|*}"; rest="${loaded#*|}"; bin="${rest%%|*}"; mode="${rest##*|}"
    log "== UI attempts in the first configuration that loaded Safari.framework: $label =="
    run_probe "$label-window" "$bin" "$mode" --try-window
    # Safari's own entry point, with a page to open and a throwaway home: its code, unsandboxed here,
    # writes its data under HOME/CFFIXED_USER_HOME, never into this user's Safari.
    home="$OUT_DIR/safari-main-home"
    rm -rf "$home"; mkdir -p "$home"
    page="$OUT_DIR/page.html"
    printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>PB graph page</title></head><body>graph</body></html>' > "$page"
    HOME="$home" CFFIXED_USER_HOME="$home" run_probe "$label-safari-main" "$bin" "$mode" --safari-main "$page"
    log "-- what Safari's code wrote under the throwaway home (history, bookmarks, website data):"
    ( cd "$home" && find . -maxdepth 6 \( -type f -o -type d \) 2>/dev/null | sort | head -150 ) | tee -a "$LOG"
fi

log ""
log "== summary =="
grep -hE '^(=================== run: |GRAPH (safari_framework_loaded|staged_loaded|staged_failed|env_DYLD_VERSIONED_FRAMEWORK_PATH|window_attempt|safari_main[a-z_]*)=|run .* exit: )' "$LOG" \
    | tee "$OUT_DIR/summary.txt" || true
log "== probe matrix complete =="
exit 0
