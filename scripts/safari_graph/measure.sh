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
OUT_DIR="$(cd "$OUT_DIR" && pwd)"   # absolute: it also becomes a throwaway HOME below
REAL_HOME="$HOME"                   # where ReportCrash writes this user's crash reports
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

# The UI. Safari's executable is a stub: its main() calls SafariMain() in Safari.framework, which runs
# NSApplicationMain with Safari's Info.plist (principal class BrowserApplication, MainMenu nib). Three
# attempts per configuration, each in a process of its own with a throwaway home (Safari's code is
# unsandboxed here and writes under HOME/CFFIXED_USER_HOME, never into this user's Safari):
#   -window       alloc/init of Safari's window controller in a plain process;
#   -safari-main  SafariMain() in the plain probe (no Info.plist of Safari's);
#   -bundle       SafariMain() in a bundle that has Safari's Info.plist (our bundle identifier) and links
#                 to Safari's resources, so NSApplicationMain makes Safari's application and nib.
# Each SafariMain run is asked to open a page served here, and the bundle run is photographed.
list_home() {
    log "-- what Safari's code wrote under $1:"
    ( cd "$1" && find . -maxdepth 7 \( -type f -o -type d \) 2>/dev/null | sort | head -200 ) | tee -a "$LOG"
}

make_bundle() {  # make_bundle APP_DIR BINARY: a bundle with Safari's Info.plist and resources; prints its executable
    local app="$1" bin="$2" safari entry name
    safari="$(cd /Applications/Safari.app 2>/dev/null && pwd -P)"
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    cp "$bin" "$app/Contents/MacOS/SafariGraphProbe"
    cp "$safari/Contents/Info.plist" "$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string dev.local.SafariGraphProbe "$app/Contents/Info.plist"
    plutil -replace CFBundleExecutable -string SafariGraphProbe "$app/Contents/Info.plist"
    for entry in "$safari/Contents"/*; do
        name="$(basename "$entry")"
        case "$name" in Info.plist|MacOS|_CodeSignature|CodeResources) continue ;; esac
        ln -s "$entry" "$app/Contents/$name"
    done
    echo "$app/Contents/MacOS/SafariGraphProbe"
}

# Why an attempt crashed: the crash reports ReportCrash wrote since MARKER (a few seconds after the
# process ended), summarized by crash_summary.py and copied to OUT_DIR/crashes.
collect_crashes() {  # collect_crashes MARKER LABEL
    local marker="$1" label="$2" reports report
    sleep 6
    reports="$(find "$REAL_HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 1 -name '*.ips' \
        -newer "$marker" 2>/dev/null | grep -E '/(SafariGraphProbe|probe)[^/]*\.ips$' || true)"
    if [ -z "$reports" ]; then log "-- no crash report for $label"; return; fi
    mkdir -p "$OUT_DIR/crashes"
    for report in $reports; do
        cp "$report" "$OUT_DIR/crashes/" 2>/dev/null
        python3 -I "$HERE/crash_summary.py" "$report" | tee -a "$LOG"
    done
}

# One attempt at the interface: its own throwaway home, then its crash report and what it wrote.
run_ui() {  # run_ui LABEL BINARY MODE [probe arguments…]
    local label="$1" bin="$2" mode="$3" home; shift 3
    home="$OUT_DIR/home-$label"; rm -rf "$home"; mkdir -p "$home"
    touch "$OUT_DIR/.marker-$label"
    HOME="$home" CFFIXED_USER_HOME="$home" GRAPH_UI_SECONDS=30 run_probe "$label" "$bin" "$mode" ${1+"$@"}
    collect_crashes "$OUT_DIR/.marker-$label" "$label"
    list_home "$home"
}

ui_attempts() {  # ui_attempts LABEL BINARY MODE
    local label="$1" bin="$2" mode="$3" exe shot
    log ""
    log "== UI attempts in configuration $label =="
    run_ui "$label-window" "$bin" "$mode" --try-window
    run_ui "$label-safari-main" "$bin" "$mode" --safari-main "$PAGE_URL"
    exe="$(make_bundle "$OUT_DIR/bundle-$label/SafariGraphProbe.app" "$bin")"
    ( for at in 10 25; do
          sleep $(( at == 10 ? 10 : 15 ))
          screencapture -x "$OUT_DIR/screen-$label-bundle-${at}s.png" >> "$LOG" 2>&1 \
              && echo "screenshot: $OUT_DIR/screen-$label-bundle-${at}s.png" >> "$LOG" || echo "screencapture failed" >> "$LOG"
      done ) &
    shot=$!
    run_ui "$label-bundle" "$exe" "$mode" --safari-main "$PAGE_URL"
    wait "$shot" 2>/dev/null
}

# The configurations to try the UI in: the first where any Safari.framework loaded, and the first where
# the user's own Safari did (on an older macOS with a newer Safari, a plain process gets the base
# system's older copy; the user's comes only with Safari's staged frameworks).
first_loaded=""; first_staged=""
for config in $CONFIGS; do
    label="${config%%|*}"
    runlog="$OUT_DIR/run-$label.log"
    if [ -z "$first_loaded" ] && grep -q '^GRAPH safari_framework_loaded=yes' "$runlog" 2>/dev/null; then first_loaded="$config"; fi
    if [ -z "$first_staged" ] && grep -q '^GRAPH safari_framework_is_users=yes' "$runlog" 2>/dev/null; then first_staged="$config"; fi
done
log ""
if [ "${GRAPH_UI:-1}" != "1" ]; then
    log "== UI attempts off (GRAPH_UI=0); Safari.framework loaded in: ${first_loaded%%|*}; the user's Safari in: ${first_staged%%|*} =="
elif [ -z "$first_loaded" ]; then
    log "== UI attempts skipped: Safari.framework loaded in no configuration =="
else
    mkdir -p "$OUT_DIR/www"
    printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>PB graph page</title></head><body>graph</body></html>' \
        > "$OUT_DIR/www/page.html"
    PAGE_PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
    ( cd "$OUT_DIR/www" && exec python3 -I -m http.server "$PAGE_PORT" --bind 127.0.0.1 ) > "$OUT_DIR/www.log" 2>&1 &
    PAGE_SERVER=$!
    PAGE_URL="http://127.0.0.1:$PAGE_PORT/page.html"
    sleep 1
    log "page for Safari's UI: $PAGE_URL"
    for config in "$first_loaded" "$first_staged"; do
        [ -n "$config" ] || continue
        label="${config%%|*}"; rest="${config#*|}"; bin="${rest%%|*}"; mode="${rest##*|}"
        case " ${tried:-} " in *" $label "*) continue ;; esac
        tried="${tried:-} $label"
        ui_attempts "$label" "$bin" "$mode"
    done
    kill "$PAGE_SERVER" 2>/dev/null
    log "-- requests the page server saw:"
    tee -a "$LOG" < "$OUT_DIR/www.log"
fi

log ""
log "== summary =="
grep -hE '^(=================== run: |== UI attempts|GRAPH (safari_framework_loaded|safari_framework_build|safari_framework_is_users|staged_loaded|staged_failed|env_DYLD_VERSIONED_FRAMEWORK_PATH|window_attempt|safari_main[a-z_]*|uncaught_exception)=|run .* exit: |screenshot: |== crash report|  (exception|termination|application-specific)|-- no crash report)' "$LOG" \
    | tee "$OUT_DIR/summary.txt" || true
log "== probe matrix complete =="
exit 0
