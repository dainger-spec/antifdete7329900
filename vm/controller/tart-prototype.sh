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
#   KEEP_VM      "1" to leave the VM running on exit (default: stop it)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/../agent" && pwd)"

TART_PID=""
TUNNEL_PID=""
KNOWN_HOSTS="$(mktemp)"

cleanup() {
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  if [[ -z "$KEEP_VM" && -n "$TART_PID" ]]; then
    echo "==> Stopping VM '$VM_NAME'"
    tart stop "$VM_NAME" 2>/dev/null || true
    kill "$TART_PID" 2>/dev/null || true
  fi
  rm -f "$KNOWN_HOSTS"
}
trap cleanup EXIT INT TERM

for tool in tart ssh scp curl; do
  command -v "$tool" &>/dev/null || { echo "$tool not found"; exit 1; }
done

# sshpass is only needed for password auth; key-based auth works without it.
SSH_WRAP=()
if command -v sshpass &>/dev/null; then
  SSH_WRAP=(sshpass -e)
fi
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS" -o ConnectTimeout=10)

ssh_vm()  { "${SSH_WRAP[@]}" ssh  "${SSH_OPTS[@]}" "$SSH_USER@$IP" "$@"; }
scp_vm()  { "${SSH_WRAP[@]}" scp  "${SSH_OPTS[@]}" "$@"; }

echo "==> Checking VM '$VM_NAME'"
if ! tart list | grep -q "[[:space:]]$VM_NAME[[:space:]]" && ! tart list | grep -q "^$VM_NAME"; then
  echo "VM not found. Create one first:"
  echo "  tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest $VM_NAME"
  exit 1
fi

echo "==> Starting VM '$VM_NAME'"
tart run "$VM_NAME" --net-bridged=en0 &
TART_PID=$!

echo "==> Waiting for VM IP..."
IP=""
for _ in $(seq 1 60); do
  IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -z "$IP" ]] && { echo "Failed to get VM IP"; exit 1; }
echo "VM IP: $IP"

echo "==> Waiting for SSH..."
for _ in $(seq 1 60); do
  if ssh_vm true 2>/dev/null; then break; fi
  sleep 2
done
ssh_vm true 2>/dev/null || { echo "SSH did not come up"; exit 1; }

echo "==> Installing in-VM agent"
ssh_vm 'mkdir -p ~/pbagent-src'
scp_vm "$AGENT_DIR/pbagent.py" "$AGENT_DIR/install.sh" \
       "$AGENT_DIR/com.privacybrowser.agent.plist.template" \
       "$SSH_USER@$IP:~/pbagent-src/"
# install.sh prints PB_AGENT_TOKEN=... on its last line.
INSTALL_OUT="$(ssh_vm "chmod +x ~/pbagent-src/install.sh && ~/pbagent-src/install.sh --port $AGENT_PORT --backend mac")"
TOKEN="$(printf '%s\n' "$INSTALL_OUT" | sed -n 's/^PB_AGENT_TOKEN=//p' | tail -1)"
[[ -z "$TOKEN" ]] && { echo "Could not read agent token from install output"; exit 1; }
echo "    agent installed; token captured"

echo "==> Opening SSH tunnel localhost:$LOCAL_PORT -> VM 127.0.0.1:$AGENT_PORT"
"${SSH_WRAP[@]}" ssh "${SSH_OPTS[@]}" -N -L "$LOCAL_PORT:127.0.0.1:$AGENT_PORT" "$SSH_USER@$IP" &
TUNNEL_PID=$!

AGENT="http://127.0.0.1:$LOCAL_PORT"
echo "==> Waiting for agent..."
for _ in $(seq 1 30); do
  if curl -fsS "$AGENT/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$AGENT/healthz" >/dev/null || { echo "Agent did not respond"; exit 1; }

echo "==> Navigating Safari to $TARGET_URL"
curl -fsS -X POST "$AGENT/navigate" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"url":"%s"}' "$TARGET_URL")"
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
