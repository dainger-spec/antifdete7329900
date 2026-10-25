#!/bin/bash
# Minimal Tart-based prototype for launching a macOS VM with Safari.
# Requires: tart (https://github.com/cirruslabs/tart)
#
# Usage:
#   ./tart-prototype.sh <vm-name> <url>
#
# This is a starting point. It does not yet include the in-VM agent.

set -euo pipefail

VM_NAME="${1:-safari-profile}"
TARGET_URL="${2:-https://browserleaks.com}"

if ! command -v tart &>/dev/null; then
  echo "tart not found. Install: brew install cirruslabs/cli/tart"
  exit 1
fi

echo "==> Checking VM '$VM_NAME'"
if ! tart list | grep -q "^$VM_NAME"; then
  echo "VM not found. Create one first:"
  echo "  tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest $VM_NAME"
  exit 1
fi

echo "==> Starting VM '$VM_NAME'"
tart run "$VM_NAME" --net-bridged=en0 &
TART_PID=$!

# Wait for VM to get an IP (simplified)
echo "==> Waiting for VM IP..."
for i in {1..30}; do
  IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
  if [[ -n "$IP" ]]; then
    echo "VM IP: $IP"
    break
  fi
  sleep 2
done

if [[ -z "${IP:-}" ]]; then
  echo "Failed to get VM IP"
  kill $TART_PID 2>/dev/null || true
  exit 1
fi

echo "==> VM is up at $IP"
echo "==> TODO: SSH into VM and open Safari to $TARGET_URL"
echo "    ssh admin@$IP 'open -a Safari $TARGET_URL'"
echo ""
echo "Press Ctrl+C to stop the VM."

wait $TART_PID
