#!/usr/bin/env bash
# scripts/site_minimum_check.py held to pages it must take and pages it must refuse (CI's Linux job).
set -uo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/site-minimum.XXXXXX")"
trap 'rm -rf "$work"' EXIT
status=0
expect() {  # expect <exit status> <what> <page text>
  local want="$1" what="$2"
  printf '%s' "$3" > "$work/page.html"
  python3 scripts/site_minimum_check.py --minimum 26.0 --page "$work/page.html" > "$work/out.txt" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then echo "PASS $what: exit $got — $(tail -n 1 "$work/out.txt")"; else
    echo "FAIL $what: exit $got, not $want — $(tail -n 1 "$work/out.txt")"; status=1; fi
}
expect 0 "the site in Russian, as the owner read it" '<p>Требуется <b>macOS&nbsp;26</b> и новее, Apple silicon.</p><script>var x="macOS 14 и новее"</script>'
expect 0 "the site in English, with the system's name" '<p>Works on macOS Tahoe 26 or later.</p>'
expect 1 "a site that says what 0.1.1's Info.plist did" '<p>Требуется macOS 14 и новее</p>'
expect 1 "a site that says 26 in one place and 15 in another" '<p>macOS 26 и новее</p><footer>macOS 15 or later</footer>'
expect 2 "a page that states no minimum" '<p>Lumen for Mac. Download.</p>'
exit $status
