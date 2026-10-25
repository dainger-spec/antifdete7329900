#!/bin/bash
# Off-Mac checks for vm/guest-proxy.sh: `--print` mode only, nothing is changed.
# Run: bash vm/test-guest-proxy.sh
set -euo pipefail

GP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guest-proxy.sh"
FAILS=0

check() { # <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAILS=$((FAILS + 1)); fi
}
has() { bash "$GP" --print "$1" | grep -cxF -- "$2" || true; }

S='<service>'
check "http sets web + secure web" \
  "$(has http://10.0.0.9:3128 "networksetup -setwebproxy $S 10.0.0.9 3128")$(has http://10.0.0.9:3128 "networksetup -setsecurewebproxy $S 10.0.0.9 3128")" "11"
check "http turns SOCKS off" "$(has http://10.0.0.9:3128 "networksetup -setsocksfirewallproxystate $S off")" "1"
check "socks5h sets SOCKS, default port 1080" "$(has socks5h://10.0.0.9 "networksetup -setsocksfirewallproxy $S 10.0.0.9 1080")" "1"
check "socks turns web proxies off" "$(has socks5://10.0.0.9:1080 "networksetup -setwebproxystate $S off")" "1"
check "http default port 80" "$(has http://10.0.0.9 "networksetup -setwebproxy $S 10.0.0.9 80")" "1"
check "PAC/WPAD off" "$(has http://10.0.0.9:1 "networksetup -setautoproxystate $S off")$(has http://10.0.0.9:1 "networksetup -setproxyautodiscovery $S off")" "11"
check "credentials percent-decoded, password masked" \
  "$(has 'socks5://us%40r:p%3Ass@10.0.0.9:1080' "networksetup -setsocksfirewallproxy $S 10.0.0.9 1080 on us@r ***")" "1"
check "password never printed" "$(bash "$GP" --print 'http://u:s3cr3t@10.0.0.9:8080' | grep -c s3cr3t || true)" "0"
check "off turns every type off" "$(bash "$GP" --print off | grep -cE ' <service> off$')" "8"
check "off sets no proxy" "$(bash "$GP" --print off | grep -cE ' -set(web|secureweb|socksfirewall)proxy ' || true)" "0"

set +e
bash "$GP" --print https://10.0.0.9:443 >/dev/null 2>&1; check "https:// refused" "$?" "1"
bash "$GP" --print ftp://10.0.0.9 >/dev/null 2>&1; check "unknown scheme refused" "$?" "1"
bash "$GP" --print 'http://10.0.0.9:x' >/dev/null 2>&1; check "bad port refused" "$?" "1"
bash "$GP" >/dev/null 2>&1; check "no argument → exit 1" "$?" "1"
set -e

# The controller's form: `set -- <url>` prepended, script on stdin.
VIA_STDIN="$({ printf 'set -- --print %q\n' 'http://u:p@10.0.0.9:3128'; cat "$GP"; } | bash -s | grep -c -- '-setwebproxy <service> 10.0.0.9 3128 on u \*\*\*')"
check "bash -s with set -- prefix" "$VIA_STDIN" "1"

[[ $FAILS -eq 0 ]] && echo "all guest-proxy checks passed" || { echo "$FAILS failed"; exit 1; }
