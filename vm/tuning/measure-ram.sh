#!/bin/bash
# Report a macOS VM's memory use, so you can compare before/after slimming.
#
# Run inside the VM (over SSH). It reads `vm_stat`, `sysctl` and `top` and
# prints memory in MiB. The host-side cost of the VM — the figure that matters
# for "how many VMs fit" — is the `tart run` process's RSS; measure that on the
# host (see vm/tuning/README.md), not here.
#
#   ./measure-ram.sh           # one human-readable sample
#   ./measure-ram.sh --json    # one sample as JSON (easy to capture over SSH)
#   ./measure-ram.sh --watch 5 # resample every 5s until Ctrl+C
#
# "used" is wired + active + compressed: memory that is genuinely occupied,
# excluding reclaimable file cache. That is the number to drive down.
set -uo pipefail

# Parse `vm_stat` (on stdin) + a page size into MiB totals. Kept separate from
# the data source so it can be tested off a Mac (feed a captured vm_stat in).
# Usage: parse_vm_stat <page_bytes>
parse_vm_stat() {
  awk -v page="$1" '
    function mib(pages) { return pages * page / 1048576 }
    /Pages free:/            { free = $NF+0 }
    /Pages active:/          { active = $NF+0 }
    /Pages inactive:/        { inactive = $NF+0 }
    /Pages speculative:/     { spec = $NF+0 }
    /Pages wired down:/      { wired = $NF+0 }
    /Pages occupied by compressor:/ { comp = $NF+0 }
    END {
      used = wired + active + comp
      printf "wired=%.0f active=%.0f inactive=%.0f speculative=%.0f compressed=%.0f free=%.0f used=%.0f\n",
             mib(wired), mib(active), mib(inactive), mib(spec), mib(comp), mib(free), mib(used)
    }'
}

# strip trailing "." that vm_stat prints and keep only digits
page_size() {
  # `vm_stat` header: "... (page size of 16384 bytes)"
  vm_stat | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p' | head -1
}

# Prints the nine numbers in a fixed order (MiB), for `read` to pick up:
#   total wired active inactive speculative compressed free used swap_used
collect() {
  local page total swap stats kv
  page="$(page_size)"; page="${page:-16384}"
  total="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))"
  # sysctl's swap line, e.g. "... used = 12.00M ..."
  swap="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')"
  swap="${swap:-0}"
  stats="$(vm_stat | parse_vm_stat "$page")"  # "wired=.. active=.. ..."
  local wired=0 active=0 inactive=0 speculative=0 compressed=0 free=0 used=0
  for kv in $stats; do
    case "$kv" in
      wired=*) wired="${kv#*=}" ;; active=*) active="${kv#*=}" ;;
      inactive=*) inactive="${kv#*=}" ;; speculative=*) speculative="${kv#*=}" ;;
      compressed=*) compressed="${kv#*=}" ;; free=*) free="${kv#*=}" ;; used=*) used="${kv#*=}" ;;
    esac
  done
  echo "$total $wired $active $inactive $speculative $compressed $free $used $swap"
}

emit_human() {
  local total wired active inactive speculative compressed free used swap_used
  read -r total wired active inactive speculative compressed free used swap_used < <(collect)
  cat <<EOF
Guest memory (MiB):
  total           $total
  used            $used      (wired + active + compressed)
    wired         $wired
    active        $active
    compressed    $compressed
  inactive        $inactive  (reclaimable file cache)
  speculative     $speculative
  free            $free
  swap used       $swap_used
EOF
}

emit_json() {
  local total wired active inactive speculative compressed free used swap_used
  read -r total wired active inactive speculative compressed free used swap_used < <(collect)
  printf '{"total_mib":%s,"used_mib":%s,"wired_mib":%s,"active_mib":%s,"compressed_mib":%s,"inactive_mib":%s,"free_mib":%s,"swap_used_mib":%s}\n' \
    "$total" "$used" "$wired" "$active" "$compressed" "$inactive" "$free" "$swap_used"
}

case "${1:-}" in
  --json)  emit_json ;;
  --watch) while true; do date "+%H:%M:%S"; emit_human; echo; sleep "${2:-5}"; done ;;
  # Reads a vm_stat dump on stdin and prints the parsed MiB totals. Lets the
  # parser be tested off a Mac with a captured sample; also handy for debugging.
  --parse-stdin) parse_vm_stat "${2:-16384}" ;;
  -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")      emit_human ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac
