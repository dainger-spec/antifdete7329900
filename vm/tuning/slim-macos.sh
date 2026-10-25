#!/bin/bash
# Slim a macOS VM down to what a headless Safari + agent needs.
#
# Run this ONCE inside the VM (over SSH from the controller/host), as the admin
# user, after the image is cloned and before you snapshot it. It turns off
# background services that waste RAM, CPU and IO in an automation VM — Spotlight
# indexing, Time Machine, Software Update, Siri, iCloud, Notification Center,
# AirDrop/Handoff/Continuity and friends — and leaves everything Safari, the
# agent, networking and SSH depend on untouched.
#
#   ./slim-macos.sh            # disable the extras
#   ./slim-macos.sh --revert   # re-enable everything this script disabled
#   ./slim-macos.sh --dry-run  # print what it would do, change nothing
#
# System Integrity Protection (on by default) refuses to disable many Apple
# daemons. This script asks for what it can, reports each as done/skipped, and
# never fails the run because SIP said no. The big, always-reliable win is the
# hard RAM cap you set on the host with `tart set --memory` (see vm/tuning).
#
# It will NOT touch anything Safari/network/SSH need — see PROTECTED below.
set -uo pipefail

MODE="apply"
case "${1:-}" in
  --revert)  MODE="revert" ;;
  --dry-run) MODE="dry-run" ;;
  -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

UID_NUM="$(id -u)"
GUI="gui/$UID_NUM"
SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# launchd labels that must keep running: the GUI (Safari needs WindowServer and
# the window manager), the login session, networking and DNS, directory/security
# and TLS trust (HTTPS!), SSH, and the service lookup/preferences plumbing every
# app uses. The script refuses to act on any of these even if listed below.
PROTECTED=(
  com.apple.WindowServer com.apple.windowserver com.apple.WindowManager
  com.apple.loginwindow com.apple.coreauthd
  com.apple.mDNSResponder com.apple.mDNSResponderHelper
  com.apple.configd com.apple.networkd com.apple.nehelper com.apple.neagent
  com.apple.opendirectoryd com.apple.securityd com.apple.trustd
  com.openssh.sshd com.apple.sshd com.apple.sshd-keygen-wrapper
  com.apple.coreservicesd com.apple.coreservices.launchservicesd
  com.apple.cfprefsd.xpc.daemon com.apple.distnoted com.apple.diskarbitrationd
  com.apple.UserEventAgent-Aqua com.apple.cfprefsd.xpc.agent
)

# Services to disable, each "domain:label[:extra]". domain = system | gui.
# Chosen to be safe for a Safari-only automation VM.
SERVICES=(
  # Spotlight: the indexer (mds_stores) is one of the hungriest idle processes.
  "system:com.apple.metadata.mds"
  "gui:com.apple.Spotlight"
  "gui:com.apple.corespotlightd"
  # Spotlight suggestions / Siri data / app "intelligence".
  "gui:com.apple.parsecd"
  "gui:com.apple.suggestd"
  "gui:com.apple.knowledge-agent"
  "gui:com.apple.assistantd"
  "gui:com.apple.Siri.agent"
  "gui:com.apple.siriknowledged"
  "gui:com.apple.siriinferenced"
  # Photo/media analysis — pure waste with no library.
  "gui:com.apple.photoanalysisd"
  "gui:com.apple.mediaanalysisd"
  # iCloud / Apple ID.
  "gui:com.apple.cloudd"
  "gui:com.apple.bird"
  "gui:com.apple.cloudphotod"
  "gui:com.apple.protectedcloudstorage.protectedcloudkeysyncing"
  "gui:com.apple.iCloudNotificationAgent"
  "gui:com.apple.itunescloudd"
  # Notification Center UI + daemon.
  "gui:com.apple.notificationcenterui.agent"
  "gui:com.apple.usernoted"
  # AirDrop / Handoff / Continuity / AirPlay.
  "system:com.apple.rapportd"
  "gui:com.apple.sharingd"
  "system:com.apple.AirPlayXPCHelper"
  # Screen Time / Family / parental, App Store housekeeping.
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

is_protected() {
  local label="$1" p
  for p in "${PROTECTED[@]}"; do [[ "$label" == "$p" ]] && return 0; done
  return 1
}

run() {
  if [[ "$MODE" == "dry-run" ]]; then
    echo "    would: $*"
    return 0
  fi
  "$@" >/dev/null 2>&1
}

DONE=0 SKIPPED=0

act_on() {
  local spec="$1" domain label target
  domain="${spec%%:*}"
  label="${spec#*:}"
  if is_protected "$label"; then
    echo "  protected, skipped: $label" >&2
    return
  fi
  case "$domain" in
    system) target="system/$label"; local SU="$SUDO" ;;
    gui)    target="$GUI/$label";   local SU="" ;;
    *) echo "  bad spec: $spec" >&2; return ;;
  esac
  if [[ "$MODE" == "revert" ]]; then
    if run $SU launchctl enable "$target"; then
      echo "  re-enabled: $target"; DONE=$((DONE + 1))
    else
      echo "  could not re-enable (ok if never present): $target"; SKIPPED=$((SKIPPED + 1))
    fi
    return
  fi
  # disable persists across boots; bootout stops it now. Either may be refused
  # by SIP for Apple daemons — that is expected and not fatal.
  local ok=1
  run $SU launchctl disable "$target" || ok=0
  run $SU launchctl bootout "$target" || true   # may already be stopped
  if [[ "$ok" == 1 ]]; then
    echo "  disabled: $target"; DONE=$((DONE + 1))
  else
    echo "  skipped (SIP or absent): $target"; SKIPPED=$((SKIPPED + 1))
  fi
}

echo "==> slim-macos ($MODE) as uid $UID_NUM"

# Subsystems with their own switches (more reliable than launchctl under SIP).
if [[ "$MODE" == "revert" ]]; then
  run $SUDO mdutil -a -i on;            echo "  Spotlight indexing: on"
  run $SUDO tmutil enable;              echo "  Time Machine: enabled"
  run $SUDO softwareupdate --schedule on; echo "  Software Update schedule: on"
else
  run $SUDO mdutil -a -i off;           echo "  Spotlight indexing: off"
  run $SUDO mdutil -a -E;               : # erase existing indexes
  run $SUDO tmutil disable;             echo "  Time Machine: disabled"
  run $SUDO softwareupdate --schedule off; echo "  Software Update schedule: off"
fi

for spec in "${SERVICES[@]}"; do
  act_on "$spec"
done

echo "==> ${MODE}: $DONE applied, $SKIPPED skipped"
if [[ "$MODE" == "apply" ]]; then
  echo "    Reboot the VM so the stopped services stay down, then snapshot it."
  echo "    Many 'skipped' lines mean SIP is on; the RAM cap (tart set --memory)"
  echo "    is the main lever regardless. See vm/tuning/README.md."
fi
