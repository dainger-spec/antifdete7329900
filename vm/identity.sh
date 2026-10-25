#!/bin/bash
# Sets a stable hardware identity for a VM profile.
# Run inside the guest (or via SSH from the controller).
#
# Usage:
#   ./identity.sh <profile-name>
#
# What it does:
#   - Sets a clean hostname (no vm/tart/virtual markers)
#   - Generates a stable MAC from the profile name (Apple OUI range)
#
# What it does not do:
#   - hw.model, serial, board-id on Apple Silicon (firmware-locked)
#   - GPU renderer strings (depend on Virtualization.framework)

set -euo pipefail

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile-name>"
  exit 1
fi

# --- Hostname ---
# Use a generic Mac-style name derived from the profile.
SAFE_NAME=$(echo "$PROFILE" | tr -cd 'A-Za-z0-9-' | head -c 20)
HOSTNAME="Mac-${SAFE_NAME}"

echo "==> Setting hostname to $HOSTNAME"
sudo scutil --set ComputerName "$HOSTNAME" 2>/dev/null || true
sudo scutil --set LocalHostName "$HOSTNAME" 2>/dev/null || true
sudo scutil --set HostName "$HOSTNAME" 2>/dev/null || true

# --- MAC address ---
# Stable per profile: hash the name, map into Apple OUI space.
# Apple OUIs commonly start with 00:1C:B3, 3C:22:FB, F0:18:98, etc.
HASH=$(echo -n "$PROFILE" | shasum -a 256 | cut -c1-6)
# Use 3C:22:FB (Apple) + 3 bytes from hash
MAC=$(printf "3C:22:FB:%s:%s:%s" "${HASH:0:2}" "${HASH:2:2}" "${HASH:4:2}" | tr 'a-f' 'A-F')

echo "==> Suggested MAC: $MAC"
echo "    Apply via Tart network config or manually in guest if needed."
echo "    Tart does not always expose MAC override; document per setup."

# --- Summary ---
echo ""
echo "Identity applied:"
echo "  Hostname: $HOSTNAME"
echo "  MAC (suggested): $MAC"
echo ""
echo "Note: hw.model / serial / board-id are not modified."
echo "On Apple Silicon these are tied to the host firmware."
