#!/usr/bin/env bash
# scripts/site_minimum_check.py held to pages it must take and pages it must refuse (CI's Linux job): one
# page, and the two download pages (/ru/download, /en/download) whose last line must name the one at fault;
# then a site served here, as release.sh asks it (--site): the root never read, an address answering 404,
# one redirected elsewhere — each named with what was found on it.
set -uo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/site-minimum.XXXXXX")"
trap 'rm -rf "$work"' EXIT
status=0
expect() {  # expect <exit status> <what> <page text> [<second page's text> [<words the last line must hold>]]
  local want="$1" what="$2" pages=(--page "$work/ru-download.html")
  printf '%s' "$3" > "$work/ru-download.html"
  if [[ $# -ge 4 ]]; then printf '%s' "$4" > "$work/en-download.html"; pages+=(--page "$work/en-download.html"); fi
  python3 scripts/site_minimum_check.py --minimum 26.0 "${pages[@]}" > "$work/out.txt" 2>&1
  local got=$? last; last="$(tail -n 1 "$work/out.txt")"
  if [[ "$got" != "$want" ]]; then echo "FAIL $what: exit $got, not $want — $last"; status=1; return; fi
  if [[ $# -ge 5 && "$last" != *"$5"* ]]; then echo "FAIL $what: the last line does not say “$5” — $last"; status=1; return; fi
  echo "PASS $what: exit $got — $last"
}
expect 0 "the site in Russian, as the owner read it" '<p>Требуется <b>macOS&nbsp;26</b> и новее, Apple silicon.</p><script>var x="macOS 14 и новее"</script>'
expect 0 "the site in English, with the system's name" '<p>Works on macOS Tahoe 26 or later.</p>'
expect 1 "a site that says what 0.1.1's Info.plist did" '<p>Требуется macOS 14 и новее</p>'
expect 1 "a site that says 26 in one place and 15 in another" '<p>macOS 26 и новее</p><footer>macOS 15 or later</footer>'
expect 0 "the system's name after the number" '<p>Нужна macOS 26 Tahoe или новее.</p>'
expect 0 "«или более поздняя»" '<li>macOS 26 или более поздняя версия</li>'
expect 2 "a page that states no minimum" '<p>Lumen for Mac. Download.</p>'
expect 2 "a page drawn by JavaScript (no text in it)" '<!doctype html><div id="root"></div><script src="/assets/index.js"></script>'
expect 1 "15 with its name after it" '<p>macOS 15 Sequoia and later</p>'
expect 0 "both download pages state 26 — both named" '<p>macOS 26 и новее</p>' '<p>macOS 26 or later</p>' "en-download.html"
expect 2 "the English page states nothing — named as such" '<p>macOS 26 и новее</p>' '<p>Download Lumen.</p>' \
  "no minimum stated on: $work/en-download.html"
expect 1 "the English page states 15 — named as such" '<p>macOS 26 и новее</p>' '<p>macOS 15 or later</p>' \
  "$work/en-download.html states macOS 15"

# A site served here: each path of routes.json answers its page, a status, or a redirect.
cat > "$work/server.py" <<'PY'
import http.server, json, sys
routes_file, port_file = sys.argv[1], sys.argv[2]
class Site(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(routes_file) as handle:
            route = json.load(handle).get(self.path, {"status": 404})
        self.send_response(route.get("status", 200))
        if "to" in route:
            self.send_header("Location", route["to"])
        body = route.get("page", "").encode()
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *arguments):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Site)
with open(port_file, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 -I "$work/server.py" "$work/routes.json" "$work/port" &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
site="http://127.0.0.1:$(cat "$work/port")"
served() {  # served <exit status> <what> <routes as JSON> <words the output must hold>...
  local want="$1" what="$2"
  printf '%s' "$3" > "$work/routes.json"
  shift 3
  NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 python3 scripts/site_minimum_check.py --minimum 26.0 --site "$site" > "$work/out.txt" 2>&1
  local got=$? last words; last="$(tail -n 1 "$work/out.txt")"
  if [[ "$got" != "$want" ]]; then echo "FAIL $what: exit $got, not $want — $(tr '\n' ' ' < "$work/out.txt")"; status=1; return; fi
  for words in "$@"; do
    grep -qF -- "$words" "$work/out.txt" || { echo "FAIL $what: the output does not say “$words” — $(tr '\n' ' ' < "$work/out.txt")"; status=1; return; }
  done
  echo "PASS $what: exit $got — $last"
}
served 0 "the site: both download pages state 26, the root states 15 and is not read" \
  '{"/": {"page": "<p>macOS 15 or later</p>"}, "/ru/download": {"page": "<p>macOS 26 и новее</p>"}, "/en/download": {"page": "<p>macOS 26 or later</p>"}}' \
  "$site/ru/download: read" "$site/en/download: read" "stated on every address asked" "$site/ru/download, $site/en/download"
served 2 "the site: the English page answers 404 — named, with its answer" \
  '{"/ru/download": {"page": "<p>macOS 26 и новее</p>"}}' \
  "$site/en/download: not read (404)" "not read: $site/en/download" "macOS 26 stated on: $site/ru/download"
served 2 "the site: the English page is redirected to the root — the root named as what was read" \
  '{"/": {"page": "<p>Lumen for Mac.</p>"}, "/ru/download": {"page": "<p>macOS 26 и новее</p>"}, "/en/download": {"status": 302, "to": "/"}}' \
  "$site/en/download: read (redirected: what was read is $site/)" "no minimum stated on: $site/en/download" \
  "$site/en/download (→ $site/)"
served 1 "the site: the Russian page states 15 — named as such" \
  '{"/ru/download": {"page": "<p>Требуется macOS 15 и новее</p>"}, "/en/download": {"page": "<p>macOS 26 or later</p>"}}' \
  "$site/ru/download states macOS 15" "Addresses asked: $site/ru/download, $site/en/download"
exit $status
