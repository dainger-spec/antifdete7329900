#!/bin/bash
# Slim a macOS VM down to what a headless Safari + agent needs: disable the
# background services that waste RAM/CPU, and reclaim disk from regenerable
# junk. Run ONCE inside the VM (over SSH), as the admin user, then reboot and
# snapshot. See vm/SLIMMING.md.
#
#   ./slim.sh                 # disable services + safe disk cleanup
#   ./slim.sh --aggressive    # also strip non-system app languages & docs
#   ./slim.sh --strip-dev     # also remove /Library/Developer (Xcode/CLT) *
#   ./slim.sh --measure       # print RAM before & after (needs measure-ram.sh)
#   ./slim.sh --dry-run       # show what it would do, change nothing
#   ./slim.sh --revert        # re-enable the services it disabled
#
# Flags combine, e.g. `./slim.sh --revert --dry-run` or `--aggressive --measure`.
#
# * --strip-dev frees the most disk but removes /usr/bin/python3 on a stock
#   image, and the agent (pbagent.py) is Python — the script refuses unless a
#   working python3 survives outside /Library/Developer, or you pass --force.
#
# What it never touches (hard allowlist): WindowServer/WindowManager/loginwindow
# (Safari needs them — there is no "headless guest" for Safari), mDNSResponder/
# configd/networkd/nehelper (networking + DNS + the proxy path), opendirectoryd/
# securityd/trustd (TLS trust — HTTPS), sshd, and Launch Services. So Safari,
# the network, HTTPS and SSH keep working.
#
# System Integrity Protection (on by default) refuses to disable many Apple
# daemons and makes /usr and /System read-only; the script asks for what it can,
# reports the rest as skipped, and never fails on a refusal. The reliable RAM
# lever is the hard cap set on the host: `tart set --memory 1536`.
set -uo pipefail

ACTION="apply"; DRY=0; AGGRESSIVE=0; STRIP_DEV=0; FORCE=0; MEASURE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY=1 ;;
    --revert)     ACTION="revert" ;;
    --aggressive) AGGRESSIVE=1 ;;
    --strip-dev)  STRIP_DEV=1 ;;
    --force)      FORCE=1 ;;
    --measure)    MEASURE=1 ;;
    -h|--help)    grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

UID_NUM="$(id -u)"
GUI="gui/$UID_NUM"
SUDO=""
[[ "$UID_NUM" -ne 0 ]] && SUDO="sudo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# launchd labels that must keep running for Safari / network / HTTPS / SSH.
PROTECTED=(
  com.apple.WindowServer com.apple.windowserver com.apple.WindowManager
  com.apple.loginwindow com.apple.coreauthd
  com.apple.mDNSResponder com.apple.mDNSResponderHelper
  com.apple.configd com.apple.networkd com.apple.nehelper com.apple.neagent
  com.apple.opendirectoryd com.apple.securityd com.apple.trustd
  com.openssh.sshd com.apple.sshd com.apple.sshd-keygen-wrapper
  com.apple.coreservicesd com.apple.coreservices.launchservicesd
  com.apple.cfprefsd.xpc.daemon com.apple.distnoted com.apple.diskarbitrationd
)

# "domain:label" to disable. domain = system | gui. Curated for a Safari-only VM.
SERVICES=(
  # Spotlight (mds / mdworker) — one of the hungriest idle processes.
  "system:com.apple.metadata.mds"
  "gui:com.apple.Spotlight"
  "gui:com.apple.corespotlightd"
  "gui:com.apple.parsecd"
  "gui:com.apple.suggestd"
  "gui:com.apple.knowledge-agent"
  # Siri.
  "gui:com.apple.assistantd"
  "gui:com.apple.Siri.agent"
  "gui:com.apple.siriknowledged"
  "gui:com.apple.siriinferenced"
  # Location services.
  "system:com.apple.locationd"
  # Analytics / diagnostics / crash reporting.
  "system:com.apple.analyticsd"
  "system:com.apple.osanalytics.osanalyticshelper"
  "system:com.apple.SubmitDiagInfo"
  "system:com.apple.spindump"
  "system:com.apple.ReportCrash"
  "gui:com.apple.ReportCrash"
  # Photo / media analysis — nothing to analyze here.
  "gui:com.apple.photoanalysisd"
  "gui:com.apple.mediaanalysisd"
  # iCloud / Apple ID.
  "gui:com.apple.cloudd"
  "gui:com.apple.bird"
  "gui:com.apple.cloudphotod"
  "gui:com.apple.protectedcloudstorage.protectedcloudkeysyncing"
  "gui:com.apple.iCloudNotificationAgent"
  "gui:com.apple.itunescloudd"
  # Notification Center.
  "gui:com.apple.notificationcenterui.agent"
  "gui:com.apple.usernoted"
  # AirDrop / Handoff / Continuity / AirPlay.
  "system:com.apple.rapportd"
  "gui:com.apple.sharingd"
  "system:com.apple.AirPlayXPCHelper"
  # Time Machine (also disabled via tmutil below).
  "system:com.apple.backupd"
  "system:com.apple.backupd-helper"
  # Software Update (also `softwareupdate --schedule off`).
  "system:com.apple.softwareupdated"
  "system:com.apple.suhelperd"
  # Screen Time / Family / App Store housekeeping.
  "gui:com.apple.ScreenTimeAgent"
  "gui:com.apple.familycircled"
  "gui:com.apple.appstoreagent"
  "gui:com.apple.commerce"
  # Assorted content daemons with nothing to do here.
  "gui:com.apple.homed"
  "gui:com.apple.newsd"
  "gui:com.apple.weatherd"
  "gui:com.apple.UsageTrackingAgent"
  "gui:com.apple.AMPArtworkAgent"
  "gui:com.apple.AMPDeviceDiscoveryAgent"
)

DISABLED=()  # for the summary

is_protected() {
  local label="$1" p
  for p in "${PROTECTED[@]}"; do [[ "$label" == "$p" ]] && return 0; done
  return 1
}

run() {
  if [[ "$DRY" == 1 ]]; then echo "    would: $*"; return 0; fi
  "$@" >/dev/null 2>&1
}

act_on() {
  local spec="$1" domain label target su
  domain="${spec%%:*}"; label="${spec#*:}"
  if is_protected "$label"; then echo "  protected, skipped: $label" >&2; return; fi
  case "$domain" in
    system) target="system/$label"; su="$SUDO" ;;
    gui)    target="$GUI/$label";   su="" ;;
    *) echo "  bad spec: $spec" >&2; return ;;
  esac
  if [[ "$ACTION" == "revert" ]]; then
    run $su launchctl enable "$target" && echo "  re-enabled: $target"
    return
  fi
  # `disable` persists across boots; `bootout` stops it now. Either may be
  # refused by SIP for Apple daemons — expected, not fatal.
  if run $su launchctl disable "$target"; then
    run $su launchctl bootout "$target" || true
    echo "  disabled: $target"; DISABLED+=("$target")
  else
    echo "  skipped (SIP or absent): $target"
  fi
}

# --- disk cleanup helpers -------------------------------------------------

free_mib() { $SUDO df -m / 2>/dev/null | awk 'NR==2{print $4}'; }

remove_glob() {
  local su="$1"; shift
  local glob path
  for glob in "$@"; do
    # shellcheck disable=SC2086  # globs must expand
    for path in $glob; do
      [[ -e "$path" ]] || continue
      if [[ "$DRY" == 1 ]]; then
        echo "    would remove $(du -sh "$path" 2>/dev/null | cut -f1)	$path"
      else
        $su rm -rf "$path" 2>/dev/null && echo "  removed: $path" || echo "  kept (locked): $path"
      fi
    done
  done
}

cleanup_disk() {
  echo "==> disk cleanup"
  # Regenerable junk on the writable data volume. (/usr and /System are a
  # sealed, read-only signed volume on modern macOS — not removable at all,
  # so there is nothing to gain from /usr/share/doc etc.)
  remove_glob ""      "$HOME/Library/Caches/"* "$HOME/Library/Logs/"* "$HOME/.Trash/"*
  remove_glob "$SUDO" "/Library/Caches/"* "/System/Library/Caches/"* \
                      "/Library/Logs/"* "/private/var/log/"*.gz "/private/var/log/asl/"* \
                      "/Library/Documentation/"* \
                      "/private/var/folders/"*/*/C/* "/private/var/folders/"*/*/T/* \
                      "/private/tmp/"*
  if command -v brew >/dev/null 2>&1; then
    if [[ "$DRY" == 1 ]]; then echo "    would: brew cleanup -s"; else brew cleanup -s >/dev/null 2>&1 || true; echo "  brew cleanup done"; fi
  fi

  if [[ "$AGGRESSIVE" == 1 ]]; then
    echo "==> aggressive: non-system app languages and docs"
    # Only non-system apps (data volume); keep English and Base. System apps
    # under /System are sealed and cannot be stripped.
    local app lproj
    for app in /Applications/*/Contents/Resources /Library/*/Resources; do
      [[ -d "$app" ]] || continue
      for lproj in "$app"/*.lproj; do
        [[ -d "$lproj" ]] || continue
        case "$(basename "$lproj")" in en.lproj|Base.lproj|English.lproj) continue ;; esac
        remove_glob "$SUDO" "$lproj"
      done
    done
  fi

  [[ "$STRIP_DEV" == 1 ]] && strip_developer
}

strip_developer() {
  echo "==> --strip-dev: /Library/Developer (Xcode / Command Line Tools)"
  local py real
  py="$(command -v python3 2>/dev/null || true)"
  real="$py"
  [[ -n "$py" ]] && real="$(readlink -f "$py" 2>/dev/null || echo "$py")"
  if [[ -n "$py" ]] && python3 -c '' 2>/dev/null \
     && [[ "$real" == *CommandLineTools* || "$real" == */Developer/* ]] && [[ "$FORCE" != 1 ]]; then
    echo "  REFUSED: python3 ($real) comes from /Library/Developer, and the agent"
    echo "           (pbagent.py) needs it. Install a standalone python3 first, or"
    echo "           pass --force to remove it anyway (the agent will stop working)."
    return
  fi
  remove_glob "$SUDO" "/Library/Developer"
}

# --- run ------------------------------------------------------------------

echo "==> slim (action=$ACTION dry=$DRY) as uid $UID_NUM"
if [[ "$MEASURE" == 1 && -x "$SCRIPT_DIR/measure-ram.sh" && "$DRY" != 1 ]]; then
  echo "--- RAM before ---"; "$SCRIPT_DIR/measure-ram.sh" || true
fi

BEFORE="$(free_mib)"

# Subsystem switches (more reliable than launchctl under SIP).
if [[ "$ACTION" == "revert" ]]; then
  run $SUDO mdutil -a -i on;               echo "  Spotlight indexing: on"
  run $SUDO tmutil enable;                 echo "  Time Machine: enabled"
  run $SUDO softwareupdate --schedule on;  echo "  Software Update schedule: on"
else
  run $SUDO mdutil -a -i off;              echo "  Spotlight indexing: off"
  run $SUDO mdutil -a -E || true;          : # drop existing indexes
  run $SUDO tmutil disable;                echo "  Time Machine: disabled"
  run $SUDO softwareupdate --schedule off; echo "  Software Update schedule: off"
fi

echo "==> services"
for spec in "${SERVICES[@]}"; do act_on "$spec"; done

[[ "$ACTION" != "revert" ]] && cleanup_disk

AFTER="$(free_mib)"

echo "==> summary (action=$ACTION dry=$DRY)"
if [[ "$ACTION" != "revert" ]]; then
  echo "  services ${DRY:+would-be-}disabled: ${#DISABLED[@]}"
  for d in ${DISABLED[@]+"${DISABLED[@]}"}; do echo "    - $d"; done
  if [[ -n "${BEFORE:-}" && -n "${AFTER:-}" && "$DRY" != 1 ]]; then
    echo "  free on / : ${BEFORE} MiB -> ${AFTER} MiB (+$((AFTER - BEFORE)) MiB)"
  fi
  echo "  Reboot so the stopped services stay down, then snapshot the VM."
  echo "  RAM is capped on the host, not here: tart set <vm> --memory 1536 --cpu 2"
fi

if [[ "$MEASURE" == 1 && -x "$SCRIPT_DIR/measure-ram.sh" && "$DRY" != 1 ]]; then
  echo "--- RAM after (reboot for the real figure) ---"; "$SCRIPT_DIR/measure-ram.sh" || true
fi

exit 0
