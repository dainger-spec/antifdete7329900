#!/bin/bash
# Sets a stable per-profile hostname in a macOS guest and prints the MAC
# address to give that profile's VM. See docs/HARDWARE_IDENTITY.md.
#
# Usage:
#   ./identity.sh <profile-name>               # inside the guest
#   ssh admin@<vm-ip> 'bash -s -- <profile-name>' < vm/identity.sh
#   ./identity.sh --print <profile-name>       # only print the values; changes
#                                              # nothing and runs anywhere
#   ./identity.sh --force <profile-name>       # skip the "is this a VM?" check
#
# The controller runs it for you when IDENTITY_PROFILE is set
# (vm/controller/tart-prototype.sh).
#
# What it does:
#   - Sets ComputerName / LocalHostName / HostName to "Mac-<profile>"
#     (scutil, needs root or passwordless sudo — the Cirrus Labs images have it)
#   - Prints a MAC derived from the profile name (Apple OUI 3C:22:FB). It is
#     NOT applied: the guest cannot change the MAC Virtualization.framework
#     gives its NIC; set it on the host (see the docs).
#
# What it does not do:
#   - hw.model, serial, board-id, kern.hv_vmm_present: fixed by
#     Virtualization.framework, not settable from the guest
#   - GPU renderer strings (Apple paravirtualized GPU)
#
# Exit status: 0 = hostname set (or --print), 1 = usage, 2 = refused (not a
# VM), 3 = scutil/sudo failed for at least one name.

set -euo pipefail

PRINT_ONLY=""
FORCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 [--print] [--force] <profile-name>" >&2
  exit 1
fi

# printf, not echo: `echo -n` prints "-n" under macOS /bin/sh, and a profile
# named "-e" would vanish.
sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-64
  else
    printf '%s' "$1" | sha256sum | cut -c1-64
  fi
}

HASH="$(sha256_hex "$PROFILE")"

# --- Hostname ---
# LocalHostName allows only ASCII letters, digits and hyphens, and must not
# start or end with a hyphen. LC_ALL=C makes tr drop non-ASCII bytes
# (e.g. a Cyrillic profile name) the same way on BSD and GNU tr.
SAFE_NAME="$(printf '%s' "$PROFILE" | LC_ALL=C tr -cd 'A-Za-z0-9-')"
SAFE_NAME="${SAFE_NAME:0:20}"
while [[ "$SAFE_NAME" == -* ]]; do SAFE_NAME="${SAFE_NAME#-}"; done
while [[ "$SAFE_NAME" == *- ]]; do SAFE_NAME="${SAFE_NAME%-}"; done
# Nothing ASCII left: fall back to a stable tag from the hash, so different
# non-Latin profiles still get different names.
[[ -z "$SAFE_NAME" ]] && SAFE_NAME="${HASH:0:8}"
HOSTNAME_NEW="Mac-${SAFE_NAME}"

# --- MAC address ---
# 3C:22:FB is an Apple OUI (globally administered, unicast), followed by three
# bytes of the profile name's SHA-256: the same name always gives the same MAC.
MAC="$(printf '3C:22:FB:%s:%s:%s' "${HASH:0:2}" "${HASH:2:2}" "${HASH:4:2}" | tr 'a-f' 'A-F')"

if [[ -n "$PRINT_ONLY" ]]; then
  echo "HOSTNAME=$HOSTNAME_NEW"
  echo "MAC=$MAC"
  exit 0
fi

# Renaming the host Mac by mistake is the failure that hurts; refuse unless
# this looks like a VM (1 in a Virtualization.framework guest).
if [[ -z "$FORCE" && "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]]; then
  echo "Refusing: this does not look like a VM (kern.hv_vmm_present != 1)." >&2
  echo "Run it inside the guest, or pass --force." >&2
  exit 2
fi

# -n: never prompt. Over `ssh ... 'bash -s' < identity.sh` stdin is this
# script, so a password prompt would hang or eat the rest of it.
as_root() {
  if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

echo "Setting hostname to $HOSTNAME_NEW"
FAILED=""
for key in ComputerName LocalHostName HostName; do
  if ! as_root scutil --set "$key" "$HOSTNAME_NEW" </dev/null; then
    echo "  could not set $key (needs root or passwordless sudo)" >&2
    FAILED=1
  fi
done

echo ""
echo "Hostname: $HOSTNAME_NEW$([[ -n "$FAILED" ]] && echo " (NOT fully applied)")"
echo "MAC (not applied, set on the host): $MAC"
echo "hw.model / serial / board-id are not modified (fixed by Virtualization.framework)."

[[ -z "$FAILED" ]] || exit 3
