#!/bin/bash
# Reclaim disk inside a freshly cloned macOS VM. Run ONCE, over SSH, before you
# snapshot the image. This frees disk, not RAM — the RAM levers are slim-macos.sh
# and `tart set --memory`. It only removes regenerable junk (caches, logs,
# temporary and trash files); it never touches the system, user data or SSH.
#
#   ./cleanup-image.sh            # clean
#   ./cleanup-image.sh --dry-run  # show sizes, remove nothing
#
# Note: Tart disks are sparse, so the image on the host shrinks only after the
# guest discards freed blocks. `tart` reclaims these automatically on stop for
# recent builds; otherwise the file keeps its high-water mark even after this.
set -uo pipefail

DRY=""
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Globs of regenerable content. User-owned paths cleared without sudo; the
# /Library and /private ones with sudo. Nothing here holds state Safari, the
# agent, networking or SSH need.
USER_TARGETS=(
  "$HOME/Library/Caches/*"
  "$HOME/Library/Logs/*"
  "$HOME/.Trash/*"
  "$HOME/Library/Developer/CoreSimulator/Caches/*"
)
SYS_TARGETS=(
  "/Library/Caches/*"
  "/Library/Logs/*"
  "/private/var/log/*"
  "/private/var/folders/*/*/C/*"   # per-user temporary caches
  "/private/tmp/*"
)

size_of() { du -sh "$@" 2>/dev/null | tail -1 | awk '{print $1}'; }

clean() {
  local sudo="$1"; shift
  local glob
  for glob in "$@"; do
    # shellcheck disable=SC2086 # globs must expand
    for path in $glob; do
      [[ -e "$path" ]] || continue
      if [[ -n "$DRY" ]]; then
        echo "  would remove $(size_of "$path")	$path"
      else
        $sudo rm -rf "$path" 2>/dev/null && echo "  removed $path" || echo "  kept (in use/locked): $path"
      fi
    done
  done
}

echo "==> cleanup-image${DRY:+ (dry-run)}"
BEFORE="$($SUDO df -m / | awk 'NR==2{print $4}')"

clean "" "${USER_TARGETS[@]}"
clean "$SUDO" "${SYS_TARGETS[@]}"

# Homebrew's own cache, if present.
if command -v brew >/dev/null 2>&1; then
  if [[ -n "$DRY" ]]; then echo "  would run: brew cleanup -s"; else brew cleanup -s >/dev/null 2>&1 || true; echo "  brew cleanup done"; fi
fi

AFTER="$($SUDO df -m / | awk 'NR==2{print $4}')"
if [[ -z "$DRY" ]]; then
  echo "==> free space on / : ${BEFORE} MiB -> ${AFTER} MiB (+$((AFTER - BEFORE)) MiB)"
  echo "    Reboot, then snapshot the VM."
fi
