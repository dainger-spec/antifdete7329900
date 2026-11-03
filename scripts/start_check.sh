#!/usr/bin/env bash
# Whether the kernel lets one of the app's executables, as signed, start: it must answer on one line
# (--keychain-probe) and end. Otherwise exit 1, with what the kernel, amfid and syspolicyd wrote
# meanwhile (AMFI, ASP, mac_vnode_check_signature).
#
#   scripts/start_check.sh <executable> <what it is, for the message>
#
# release.sh runs it on the app's executable and the profile's (LumenProfile) before anything is
# sent to Apple's notary (step 1b): on 3 November 0.1.1 with the network guard was notarized, then
# killed by the kernel at its start on macOS 27.0.1 (docs/TUNNEL.md, "Status"). CI holds it to a copy
# the kernel refuses — an ad hoc signature carrying an application identifier — which must fail.
set -uo pipefail
executable="${1:?usage: start_check.sh <executable> <what it is>}"
name="${2:-$1}"
since="$(date '+%Y-%m-%d %H:%M:%S')"
status=0
output="$(env -u PB_PROFILE_PROCESS -u PB_SAFARI_CHROME "$executable" --keychain-probe start-check 2>&1)" || status=$?
if [[ "$output" == *"KEYCHAIN-PROBE {"* ]]; then
  echo "start check: $name starts as signed"
  exit 0
fi
echo "error: $name did not start as signed (exit status $status). The kernel and the system's policy said:" >&2
sleep 1
log show --style compact --start "$since" --predicate 'process == "kernel" OR process == "amfid" OR process == "syspolicyd"' 2>/dev/null \
  | grep -E 'AMFI|ASP:|mac_vnode_check_signature|Security policy' | tail -n 12 >&2 || true
echo "(scripts/amfi_matrix.py measures which right or relaxation it is refused for)" >&2
exit 1
