#!/bin/bash
# Points macOS (and so Safari) in the guest at the profile's proxy, on every
# network service, or turns all proxies off. See docs/PROFILES.md.
#
# Usage:
#   ./guest-proxy.sh <proxy-url>     # inside the guest
#   ./guest-proxy.sh off
#   ./guest-proxy.sh --print <proxy-url|off>   # print the networksetup calls
#                                              # (password masked); changes nothing
#
# The controller pipes this script to `ssh … 'bash -s'` with the URL prepended
# as `set -- <url>`, so the credentials never appear in a host-side argv.
#
# <proxy-url>: http://[user:pass@]host[:port]           (default port 80)
#              socks5://, socks5h://, socks4://…        (default port 1080)
# user/pass may be percent-encoded. https:// (TLS to the proxy) is refused:
# the macOS system proxy cannot speak it.
#
# Fail-closed context: softnet only lets the VM reach the proxy's IP, so this
# is what makes pages load at all; a mistake here means no internet, not a leak.
#
# Exit status: 0 = applied, 1 = usage / unsupported URL, 3 = networksetup failed.

set -euo pipefail

PRINT=""
if [[ "${1:-}" == "--print" ]]; then PRINT=1; shift; fi
URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo "Usage: $0 [--print] <proxy-url|off>" >&2
  exit 1
fi

percent_decode() { local v="${1//+/ }"; printf '%b' "${v//%/\\x}"; }

KIND="" HOST="" PORT="" USER_NAME="" PASSWORD=""
if [[ "$URL" != "off" ]]; then
  SCHEME="$(printf '%s' "${URL%%://*}" | tr 'A-Z' 'a-z')"
  [[ "$URL" == *"://"* ]] || { echo "Not a proxy URL: scheme://host:port expected" >&2; exit 1; }
  REST="${URL#*://}"
  REST="${REST%%/*}"
  if [[ "$REST" == *"@"* ]]; then
    CREDS="${REST%@*}"
    REST="${REST##*@}"
    USER_NAME="$(percent_decode "${CREDS%%:*}")"
    [[ "$CREDS" == *":"* ]] && PASSWORD="$(percent_decode "${CREDS#*:}")"
  fi
  HOST="${REST%%:*}"
  [[ "$REST" == *":"* ]] && PORT="${REST##*:}"
  case "$SCHEME" in
    http) KIND=web; PORT="${PORT:-80}" ;;
    socks5|socks5h|socks4|socks) KIND=socks; PORT="${PORT:-1080}" ;;
    https) echo "https:// proxies (TLS to the proxy) are not supported by the macOS system proxy; use http:// or socks5://" >&2; exit 1 ;;
    *) echo "Unsupported proxy scheme: $SCHEME" >&2; exit 1 ;;
  esac
  [[ -n "$HOST" ]] || { echo "Proxy URL has no host" >&2; exit 1; }
  [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Proxy port is not a number: $PORT" >&2; exit 1; }
fi

if [[ -z "$PRINT" ]] && ! command -v networksetup >/dev/null 2>&1; then
  echo "networksetup not found: run this inside the macOS guest" >&2
  exit 1
fi

# All enabled services (the first line is a legend; '*' marks disabled ones).
SERVICES=()
if command -v networksetup >/dev/null 2>&1; then
  while IFS= read -r service; do
    [[ -z "$service" || "$service" == \** ]] && continue
    SERVICES+=("$service")
  done < <(networksetup -listallnetworkservices | tail -n +2)
fi
[[ ${#SERVICES[@]} -gt 0 ]] || SERVICES=("<service>")

FAILED=""
# -n: never prompt (stdin is this script under `bash -s`).
ns() {
  if [[ -n "$PRINT" ]]; then
    local shown=("$@")
    [[ -n "$PASSWORD" && "${shown[${#shown[@]}-1]}" == "$PASSWORD" ]] && shown[${#shown[@]}-1]="***"
    echo "networksetup ${shown[*]}"
    return 0
  fi
  local run=(networksetup "$@")
  [[ "$EUID" -eq 0 ]] || run=(sudo -n networksetup "$@")
  "${run[@]}" </dev/null >/dev/null || { echo "  failed: networksetup $1 $2" >&2; FAILED=1; }
}

for service in "${SERVICES[@]}"; do
  # Nothing may route around the chosen proxy: no PAC/WPAD, no other types.
  ns -setautoproxystate "$service" off
  ns -setproxyautodiscovery "$service" off
  ns -setftpproxystate "$service" off
  ns -setstreamingproxystate "$service" off
  ns -setgopherproxystate "$service" off
  auth=()
  [[ -n "$USER_NAME" ]] && auth=(on "$USER_NAME" "$PASSWORD")
  case "$KIND" in
    web)
      ns -setwebproxy "$service" "$HOST" "$PORT" ${auth[@]+"${auth[@]}"}
      ns -setsecurewebproxy "$service" "$HOST" "$PORT" ${auth[@]+"${auth[@]}"}
      ns -setsocksfirewallproxystate "$service" off ;;
    socks)
      ns -setsocksfirewallproxy "$service" "$HOST" "$PORT" ${auth[@]+"${auth[@]}"}
      ns -setwebproxystate "$service" off
      ns -setsecurewebproxystate "$service" off ;;
    *)
      ns -setwebproxystate "$service" off
      ns -setsecurewebproxystate "$service" off
      ns -setsocksfirewallproxystate "$service" off ;;
  esac
done

[[ -n "$PRINT" ]] && exit 0
if [[ -n "$FAILED" ]]; then
  echo "Proxy NOT fully applied (needs root or passwordless sudo)" >&2
  exit 3
fi
if [[ -n "$KIND" ]]; then
  echo "Proxy set: $KIND $HOST:$PORT$([[ -n "$USER_NAME" ]] && echo " (user $USER_NAME)") on ${#SERVICES[@]} service(s)"
else
  echo "Proxies off on ${#SERVICES[@]} service(s)"
fi
