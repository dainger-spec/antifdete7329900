#!/usr/bin/env bash
# Off-device checks for the packet tunnel: type-checks PacketTunnelProvider.swift + Relay.swift
# against the stand-ins in Stubs.swift/NEStubs.swift and runs the relay scenario tests.
# Needs only `swiftc` (Linux or macOS); no entitlement, no Xcode project. This is NOT a substitute
# for the NE=1 build and the hardware checklist in ../../docs/NETWORK.md.
set -euo pipefail
cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Drop the framework imports: the stubs stand in for them.
sed -E '/^import (Network|NetworkExtension|Security|os)$/d' ../Relay.swift > "$WORK/Relay.swift"
sed -E '/^import (NetworkExtension|os)$/d' ../PacketTunnelProvider.swift > "$WORK/Provider.swift"
if [[ "$(uname)" == "Linux" ]]; then
  # Glibc spells SOCK_STREAM as an enum; Darwin as Int32 (what the provider is written for).
  sed -i 's/hints.ai_socktype = SOCK_STREAM/hints.ai_socktype = Int32(SOCK_STREAM.rawValue)/' "$WORK/Provider.swift"
fi
# The keychain lookup is Security.framework only; stub its body for the type-check.
python3 - "$WORK/Provider.swift" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index('    private static func keychainPassword'); j = s.index('    enum TunnelError')
open(p, 'w').write(s[:i] + '    private static func keychainPassword(_ reference: Data?) -> String? { nil }\n\n' + s[j:])
PY

echo "== type-check provider + relay against the stand-ins"
swiftc -typecheck -swift-version 5 Stubs.swift NEStubs.swift "$WORK/Relay.swift" "$WORK/Provider.swift"

status=0
for t in relay-tcp relay-proxy relay-udp-dns-ipv6; do
  echo "== $t"
  swiftc -swift-version 5 -O Stubs.swift "$WORK/Relay.swift" "$t/main.swift" -o "$WORK/$t"
  "$WORK/$t" || status=1
done
exit $status
