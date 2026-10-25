#!/bin/bash
# Tart-based prototype: launch a macOS VM, install the in-VM agent, and drive
# the VM's real Safari to a URL through it.
#
# Requires on the host: tart (https://github.com/cirruslabs/tart), ssh/scp,
# curl. Optional: sshpass (for password auth to the stock Tart image).
#
# Usage:
#   ./tart-prototype.sh <vm-name> <url>
#
# Environment overrides:
#   SSH_USER     VM login user              (default: admin)
#   SSHPASS      VM login password          (default: admin; used via sshpass)
#   AGENT_PORT   agent port inside the VM   (default: 8777)
#   LOCAL_PORT   host end of the SSH tunnel (default: AGENT_PORT)
#   SHOT         path to save a screenshot  (default: none)
#   COOKIES_FILE path to a cookies JSON array (CookieImport output); applied to
#                Safari via POST /cookies before navigating
#   FORCE_INSTALL  "1" to reinstall the agent even if it is already installed
#   KEEP_VM      "1" to leave the VM running on exit (default: stop it)
#   TART_NET     "bridged" (default; --net-bridged=$BRIDGE_IF, IP via ARP),
#                "shared" (Tart NAT), or "softnet" (fail-closed isolation)
#   BRIDGE_IF    host interface for bridged networking (default: en0)
#   SOFTNET_ALLOW  with TART_NET=softnet: egress-allowed CIDR(s), e.g. the proxy
#                  (comma-separated). Empty = no egress. Needs the softnet helper.
#   VM_MEMORY    RAM cap in MiB, applied with `tart set` (empty = image default)
#   VM_CPU       CPU core count, applied with `tart set` (empty = image default)
#   VM_HEADLESS  "1" (default) = run with --no-graphics: no host window with the
#                guest desktop; Safari still renders on the guest's display.
#                "0" or empty = show the VM window. See vm/SLIMMING.md.
#   IP_TIMEOUT   seconds to wait for the VM's IP before failing (default: 120)
#   VM_RUN_ARGS  extra flags appended to `tart run`, split on spaces (e.g. to
#                pass a build-specific device toggle your tart supports)
#   IDENTITY_PROFILE  profile name: once SSH is up, run vm/identity.sh in the
#                guest to set a stable hostname for it (empty = skip). Failure
#                is reported and the launch continues. See docs/HARDWARE_IDENTITY.md.
#
# This installs vm/agent/ into the VM as a LaunchAgent, opens an SSH tunnel to
# the agent's loopback port, then calls POST /navigate. The agent control port
# is never exposed on the VM's network interface.

set -euo pipefail

VM_NAME="${1:-safari-profile}"
TARGET_URL="${2:-https://browserleaks.com}"

SSH_USER="${SSH_USER:-admin}"
export SSHPASS="${SSHPASS:-admin}"
AGENT_PORT="${AGENT_PORT:-8777}"
LOCAL_PORT="${LOCAL_PORT:-$AGENT_PORT}"
SHOT="${SHOT:-}"
KEEP_VM="${KEEP_VM:-}"
TART_NET="${TART_NET:-bridged}"
BRIDGE_IF="${BRIDGE_IF:-en0}"
VM_MEMORY="${VM_MEMORY:-}"
VM_CPU="${VM_CPU:-}"
# Unset → headless; an explicit empty value keeps its old meaning (window).
VM_HEADLESS="${VM_HEADLESS-1}"
[[ "$VM_HEADLESS" == "0" ]] && VM_HEADLESS=""
IP_TIMEOUT="${IP_TIMEOUT:-120}"
VM_RUN_ARGS="${VM_RUN_ARGS:-}"
IDENTITY_PROFILE="${IDENTITY_PROFILE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/../agent" && pwd)"

TART_PID=""
TUNNEL_PID=""
KNOWN_HOSTS="$(mktemp)"

cleanup() {
  # Runs from the INT/TERM trap and again from EXIT; do the work only once.
  [[ -n "${_CLEANED:-}" ]] && return
  _CLEANED=1
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  if [[ -z "$KEEP_VM" && -n "$TART_PID" ]]; then
    echo "==> Stopping VM '$VM_NAME'"
    tart stop "$VM_NAME" 2>/dev/null || true
    kill "$TART_PID" 2>/dev/null || true
  fi
  rm -f "$KNOWN_HOSTS"
}
trap cleanup EXIT
# Exit on INT/TERM (the EXIT trap then cleans up). A trap that only ran cleanup
# would resume the script afterwards — e.g. keep polling for the VM's IP — when
# the signal reaches bash alone rather than the whole terminal process group.
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in tart ssh scp curl; do
  command -v "$tool" &>/dev/null || { echo "$tool not found"; exit 1; }
done
# Tart starts the softnet helper itself; without it `tart run --net-softnet`
# dies at once and the VM never gets an address.
if [[ "$TART_NET" == "softnet" ]] && ! command -v softnet &>/dev/null; then
  echo "softnet not found (TART_NET=softnet needs it: brew install cirruslabs/cli/softnet)"
  exit 1
fi

# sshpass is only needed for password auth; key-based auth works without it.
# Default to a no-op `env` prefix rather than an empty array: on macOS /bin/bash
# is 3.2, where expanding an empty array as "${SSH_WRAP[@]}" under `set -u`
# aborts with "unbound variable". `env ssh …` is a harmless passthrough.
SSH_WRAP=(env)
if command -v sshpass &>/dev/null; then
  SSH_WRAP=(sshpass -e)
fi
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS" -o ConnectTimeout=10)

# `tart ip` reads the host's DHCP leases by default, which only cover Tart's NAT
# network; a bridged VM gets its address from the LAN and is found via ARP.
# Arrays may be empty: "${a[@]+"${a[@]}"}" keeps bash 3.2 happy under `set -u`.
case "$TART_NET" in
  bridged) RUN_NET_ARGS=(--net-bridged="$BRIDGE_IF"); IP_ARGS=(--resolver=arp) ;;
  shared)  RUN_NET_ARGS=(); IP_ARGS=() ;;
  # Fail-closed isolation via the softnet helper: egress only to SOFTNET_ALLOW
  # (a CIDR, or comma-separated CIDRs) — set it to the proxy. Empty allow = no
  # egress at all. See vm/SLIMMING.md / docs/PROFILES.md.
  softnet)
    RUN_NET_ARGS=(--net-softnet)
    [[ -n "${SOFTNET_ALLOW:-}" ]] && RUN_NET_ARGS+=(--net-softnet-allow "$SOFTNET_ALLOW")
    IP_ARGS=() ;;
  *) echo "TART_NET must be 'bridged', 'shared' or 'softnet' (got '$TART_NET')"; exit 2 ;;
esac

ssh_vm()  { "${SSH_WRAP[@]}" ssh  "${SSH_OPTS[@]}" "$SSH_USER@$IP" "$@"; }
scp_vm()  { "${SSH_WRAP[@]}" scp  "${SSH_OPTS[@]}" "$@"; }

echo "==> Checking VM '$VM_NAME'"
if ! tart list | grep -q "[[:space:]]${VM_NAME}[[:space:]]" && ! tart list | grep -q "^${VM_NAME}"; then
  echo "VM not found. Create one first:"
  echo "  tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest $VM_NAME"
  exit 1
fi

# Apply RAM/CPU caps while the VM is stopped (see vm/SLIMMING.md for sizing).
if [[ -n "$VM_MEMORY$VM_CPU" ]]; then
  SET_ARGS=()
  [[ -n "$VM_MEMORY" ]] && SET_ARGS+=(--memory "$VM_MEMORY")
  [[ -n "$VM_CPU" ]] && SET_ARGS+=(--cpu "$VM_CPU")
  echo "    sizing: tart set ${SET_ARGS[*]}"
  tart set "$VM_NAME" "${SET_ARGS[@]}"
fi

RUN_ARGS=(${RUN_NET_ARGS[@]+"${RUN_NET_ARGS[@]}"})
# --no-graphics drops the host window. Safari still renders on the guest's
# virtual display; if your Tart build removes that display headless and
# screenshots/pages break, set VM_HEADLESS=0 (see vm/SLIMMING.md).
[[ -n "$VM_HEADLESS" ]] && RUN_ARGS+=(--no-graphics)
# Extra run flags, space-split (e.g. a device toggle specific to your tart).
if [[ -n "$VM_RUN_ARGS" ]]; then
  read -ra _EXTRA_RUN_ARGS <<< "$VM_RUN_ARGS"
  RUN_ARGS+=("${_EXTRA_RUN_ARGS[@]}")
fi

echo "==> Starting VM '$VM_NAME'"
tart run "$VM_NAME" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} &
TART_PID=$!

# Two VMs with one MAC (e.g. a profile imported next to its source) get the
# same DHCP lease: `tart ip` then finds the other VM's address, or none.
VMS_DIR="${TART_HOME:-$HOME/.tart}/vms"
mac_of() { sed -n 's/.*"macAddress" *: *"\([^"]*\)".*/\1/p' "$VMS_DIR/$1/config.json" 2>/dev/null | head -1 || true; }
OWN_MAC="$(mac_of "$VM_NAME")"
if [[ -n "$OWN_MAC" ]]; then
  for dir in "$VMS_DIR"/*/; do
    other="$(basename "$dir")"
    [[ "$other" != "$VM_NAME" && "$(mac_of "$other")" == "$OWN_MAC" ]] || continue
    echo "    warning: '$other' has the same MAC $OWN_MAC; fix with: tart set $VM_NAME --random-mac"
  done
fi

echo "==> Waiting for VM IP..."
IP=""
WAITED=0
while (( WAITED < IP_TIMEOUT )); do
  # tart run failing at once (VM already running, Apple's limit of two macOS
  # VMs, softnet refusing to start) used to look like a slow boot. Checked
  # before `tart ip`: a VM someone else already runs has an IP, but not ours.
  if ! kill -0 "$TART_PID" 2>/dev/null; then
    rc=0; wait "$TART_PID" || rc=$?
    TART_PID="" # nothing of ours to stop; don't `tart stop` someone else's VM
    echo "tart run exited before the VM got an IP (code $rc, TART_NET=$TART_NET); its error is above"
    exit 1
  fi
  IP="$(tart ip ${IP_ARGS[@]+"${IP_ARGS[@]}"} "$VM_NAME" 2>/dev/null || true)"
  [[ -n "$IP" ]] && kill -0 "$TART_PID" 2>/dev/null && break
  IP=""
  sleep 2
  WAITED=$((WAITED + 2))
  (( WAITED % 10 == 0 )) && echo "    still waiting for VM IP (${WAITED}s of ${IP_TIMEOUT}s, TART_NET=$TART_NET)"
done
if [[ -z "$IP" ]]; then
  echo "Failed to get VM IP after ${IP_TIMEOUT}s (TART_NET=$TART_NET)"
  case "$TART_NET" in
    bridged) echo "    bridged: the address is found via ARP on $BRIDGE_IF; the VM must get a LAN DHCP lease (try TART_NET=shared)" ;;
    *) echo "    $TART_NET: the address comes from the host's DHCP leases (/var/db/dhcpd_leases); check the VM window (VM_HEADLESS=0) to see if macOS booted" ;;
  esac
  echo "    running VMs: $(tart list 2>/dev/null | awk '$NF == "running" {print $2}' | tr '\n' ' ')"
  exit 1
fi
echo "VM IP: $IP"

echo "==> Waiting for SSH..."
for _ in $(seq 1 60); do
  if ssh_vm true 2>/dev/null; then break; fi
  sleep 2
done
ssh_vm true 2>/dev/null || { echo "SSH did not come up"; exit 1; }

if [[ -n "$IDENTITY_PROFILE" ]]; then
  echo "==> Setting hardware identity for '$IDENTITY_PROFILE'"
  IDENTITY_SH="$SCRIPT_DIR/../identity.sh"
  if [[ ! -r "$IDENTITY_SH" ]]; then
    echo "    identity.sh not found next to the controller (skipping)"
  # The script goes over stdin; %q keeps any profile name one argument for the
  # guest's login shell (zsh understands bash's quoting, $'…' included).
  elif ssh_vm "bash -s -- $(printf '%q' "$IDENTITY_PROFILE")" < "$IDENTITY_SH"; then
    echo "    hardware identity applied"
  else
    echo "    hardware identity not fully applied (continuing)"
  fi
fi

echo "==> Installing in-VM agent"
# Install once: if the agent is already installed (its token file exists) and
# FORCE_INSTALL is unset, reuse it instead of copying and reinstalling. The
# LaunchAgent keeps it running across reboots, so this is the common path.
TOKEN=""
if [[ -z "${FORCE_INSTALL:-}" ]]; then
  TOKEN="$(ssh_vm 'cat ~/.pbagent/token 2>/dev/null' 2>/dev/null || true)"
fi
if [[ -n "$TOKEN" ]]; then
  echo "    agent already installed; reusing token"
else
  ssh_vm 'mkdir -p ~/pbagent-src'
  scp_vm "$AGENT_DIR/pbagent.py" "$AGENT_DIR/binarycookies.py" "$AGENT_DIR/install.sh" \
         "$AGENT_DIR/com.privacybrowser.agent.plist.template" \
         "$SSH_USER@$IP:~/pbagent-src/"
  # install.sh prints PB_AGENT_TOKEN=... on its last line.
  INSTALL_OUT="$(ssh_vm "chmod +x ~/pbagent-src/install.sh && ~/pbagent-src/install.sh --port $AGENT_PORT --backend mac")"
  TOKEN="$(printf '%s\n' "$INSTALL_OUT" | sed -n 's/^PB_AGENT_TOKEN=//p' | tail -1)"
  [[ -z "$TOKEN" ]] && { echo "Could not read agent token from install output"; exit 1; }
  echo "    agent installed; token captured"
fi

echo "==> Opening SSH tunnel localhost:$LOCAL_PORT -> VM 127.0.0.1:$AGENT_PORT"
# ExitOnForwardFailure: if LOCAL_PORT is taken, fail instead of leaving a tunnel
# without a forward (curl would then talk to whatever owns that port).
"${SSH_WRAP[@]}" ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
  -N -L "$LOCAL_PORT:127.0.0.1:$AGENT_PORT" "$SSH_USER@$IP" &
TUNNEL_PID=$!

AGENT="http://127.0.0.1:$LOCAL_PORT"
echo "==> Waiting for agent..."
for _ in $(seq 1 30); do
  if curl -fsS "$AGENT/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$AGENT/healthz" >/dev/null || { echo "Agent did not respond"; exit 1; }

# Apply per-profile cookies before navigating, if a cookie file was given.
# COOKIES_FILE is the agent-shaped JSON array (CookieImport output); wrap it as
# {"cookies": [...]} for POST /cookies.
if [[ -n "${COOKIES_FILE:-}" ]]; then
  if [[ -f "$COOKIES_FILE" ]]; then
    echo "    applying cookies from $COOKIES_FILE"
    { printf '{"cookies":'; cat "$COOKIES_FILE"; printf '}'; } | curl -fsS -X POST "$AGENT/cookies" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- && echo || \
      echo "    cookie import failed (continuing)"
  else
    echo "    COOKIES_FILE not found: $COOKIES_FILE (skipping)"
  fi
fi

echo "==> Navigating Safari to $TARGET_URL"
# Escape backslashes and quotes so any URL makes valid JSON (sed behaves the
# same in BSD and GNU, unlike ${var//…} replacement quoting across bash versions).
URL_JSON="$(printf '%s' "$TARGET_URL" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
curl -fsS -X POST "$AGENT/navigate" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$URL_JSON\"}"
echo

echo "==> Status:"
curl -fsS "$AGENT/status" -H "Authorization: Bearer $TOKEN"; echo

if [[ -n "$SHOT" ]]; then
  echo "==> Saving screenshot to $SHOT"
  curl -fsS "$AGENT/screenshot" -H "Authorization: Bearer $TOKEN" -o "$SHOT"
fi

echo
echo "VM is up at $IP, Safari pointed at the target."
echo "Press Ctrl+C to stop the tunnel$([[ -z "$KEEP_VM" ]] && echo " and the VM")."
wait "$TART_PID"
