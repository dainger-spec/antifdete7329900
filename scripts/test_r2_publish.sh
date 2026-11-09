#!/usr/bin/env bash
# scripts/r2_publish.sh against a local R2 (scripts/r2_local.py, which checks every request's
# signature and every upload's SHA-256 as R2 does): what a release does on dl.lumenbrowser.io, made
# to work and made to fail, on every push (CI) — the path is not untested code on a release's day.
#
#   scripts/test_r2_publish.sh
#
# Needs python3, openssl and curl 7.88 or newer (curl's SigV4 for S3, with the payload's hash given).
set -euo pipefail
cd "$(dirname "$0")/.."

T="$(mktemp -d "${TMPDIR:-/tmp}/r2-test.XXXXXX")"
SERVER=""
cleanup() { [[ -z "$SERVER" ]] || kill "$SERVER" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# A certificate for 127.0.0.1 that curl is told to trust: the scripts take https addresses only.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
ID="0123456789abcdef0123456789abcdef"
SECRET="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
python3 scripts/r2_local.py --state "$T/state" --cert "$T/cert.pem" --key "$T/key.pem" --bucket lumen-downloads \
  --key-id "$ID" --secret "$SECRET" > "$T/ports" &
SERVER=$!
for _ in $(seq 50); do [[ -s "$T/ports" ]] && break; sleep 0.1; done
read -r API PUBLIC < "$T/ports" || { echo "the local R2 did not start" >&2; exit 1; }

# curl as the scripts run it, through a wrapper that keeps its arguments: the keys must never be
# among them (ps shows them to every user of the Mac).
REAL_CURL="$(command -v curl)"
mkdir "$T/bin"
cat > "$T/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/curl-arguments"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" CURL_CA_BUNDLE="$T/cert.pem" NO_PROXY="127.0.0.1" no_proxy="127.0.0.1"
unset R2_BUCKET
export R2_ENDPOINT="https://127.0.0.1:$API" R2_ACCESS_KEY_ID="$ID" R2_SECRET_ACCESS_KEY="$SECRET"
BASE="https://127.0.0.1:$PUBLIC"
DMG_TYPE="application/x-apple-diskimage" FOREVER="public, max-age=31536000, immutable"
set +e  # every case runs and is counted

run() { # expected (ok|fails), what, command…: the output in $T/out, all of it in $T/all
  local expected="$1" what="$2" status=0
  shift 2
  "$@" > "$T/out" 2>&1 || status=$?
  cat "$T/out" >> "$T/all"
  if [[ "$expected" == ok && $status -ne 0 ]] || [[ "$expected" == fails && $status -eq 0 ]]; then
    fail "$what (exit $status)"; sed 's/^/    /' "$T/out" >&2; return 1
  fi
  pass "$what"
}
said() { grep -q -- "$1" "$T/out" || { fail "the output does not say: $1"; sed 's/^/    /' "$T/out" >&2; }; }
puts() { grep -c "\"method\": \"PUT\".*\"name\": \"$1\"" "$T/state/log.jsonl" || true; }

head -c 300000 /dev/urandom > "$T/Lumen-9.9.9.dmg"
SHA="$(shasum -a 256 "$T/Lumen-9.9.9.dmg" | cut -d' ' -f1)"

run ok "a name not published yet is free" scripts/r2_publish.sh --free "$BASE/Lumen-9.9.9.dmg" && said "free in lumen-downloads"
run ok "the image is uploaded and read back the same" \
  scripts/r2_publish.sh "$T/Lumen-9.9.9.dmg" "$BASE/Lumen-9.9.9.dmg" "$DMG_TYPE" "$FOREVER" && said "read back — sha256 $SHA"
grep "\"method\": \"PUT\".*\"name\": \"Lumen-9.9.9.dmg\"" "$T/state/log.jsonl" > "$T/put" || true
grep -q "\"payload\": \"$SHA\"" "$T/put" && grep -q '"x-amz-content-sha256"' "$T/put" \
  && pass "the upload signed the file's SHA-256 (R2 checks the bytes against it)" \
  || fail "the upload did not sign the file's SHA-256: $(cat "$T/put")"
"$REAL_CURL" -sS -D "$T/served" -o /dev/null "$BASE/Lumen-9.9.9.dmg"
grep -qi "^content-type: $DMG_TYPE" "$T/served" && grep -qi "^cache-control: $FOREVER" "$T/served" \
  && pass "served with its type and a year's cache" || fail "served with: $(tr -d '\r' < "$T/served")"
run fails "the name is taken now" scripts/r2_publish.sh --free "$BASE/Lumen-9.9.9.dmg" && said "never replaced"
run ok "the same bytes again are left as they are, and read back" \
  scripts/r2_publish.sh "$T/Lumen-9.9.9.dmg" "$BASE/Lumen-9.9.9.dmg" "$DMG_TYPE" "$FOREVER" && said "the same bytes"
[[ "$(puts Lumen-9.9.9.dmg)" == 1 ]] && pass "and not uploaded twice" || fail "uploaded $(puts Lumen-9.9.9.dmg) times"
head -c 300000 /dev/urandom > "$T/other.dmg"
run fails "other bytes never replace a published version" \
  scripts/r2_publish.sh "$T/other.dmg" "$BASE/Lumen-9.9.9.dmg" "$DMG_TYPE" "$FOREVER" && said "never replaced"
[[ "$(puts Lumen-9.9.9.dmg)" == 1 ]] && pass "and nothing was uploaded" || fail "uploaded $(puts Lumen-9.9.9.dmg) times"

echo '{"format": 1, "first": true}' > "$T/appcast-1.json"
echo '{"format": 1, "second": true}' > "$T/appcast-2.json"
run ok "no appcast yet: none to keep" scripts/r2_publish.sh --current "$BASE/appcast.json" "$T/previous.json" && said "none in lumen-downloads yet"
[[ ! -e "$T/previous.json" ]] && pass "and no file" || fail "a file was left for an appcast that is not there"
run ok "the appcast is uploaded" scripts/r2_publish.sh "$T/appcast-1.json" "$BASE/appcast.json" application/json no-cache --replace
run ok "and replaced by the next release's" scripts/r2_publish.sh "$T/appcast-2.json" "$BASE/appcast.json" application/json no-cache --replace
run fails "without --replace the appcast is not replaced either" \
  scripts/r2_publish.sh "$T/appcast-1.json" "$BASE/appcast.json" application/json no-cache
run ok "the appcast published now is fetched from the bucket" scripts/r2_publish.sh --current "$BASE/appcast.json" "$T/previous.json"
cmp -s "$T/previous.json" "$T/appcast-2.json" && pass "and it is the latest" || fail "the appcast fetched is not the latest"

# What is served is not what was built: the release fails, and says so.
head -c 200000 /dev/urandom > "$T/Lumen-9.9.10.dmg"
echo "Lumen-9.9.10.dmg" > "$T/state/corrupt"
run fails "a public address serving other bytes fails the release" \
  scripts/r2_publish.sh "$T/Lumen-9.9.10.dmg" "$BASE/Lumen-9.9.10.dmg" "$DMG_TYPE" "$FOREVER" && said "serves other bytes" && said "The release has failed"
rm "$T/state/corrupt"
# A public address that is not the bucket's (the domain not connected to it): uploaded, never served.
run fails "an address that does not serve the bucket fails the release" \
  scripts/r2_publish.sh "$T/Lumen-9.9.10.dmg" "https://127.0.0.1:$API/Lumen-9.9.12.dmg" "$DMG_TYPE" "$FOREVER" && said "where Lumen-9.9.10.dmg was just published"

WRONG="${SECRET//f/0}"
run fails "a wrong secret is refused" env R2_SECRET_ACCESS_KEY="$WRONG" \
  scripts/r2_publish.sh --free "$BASE/Lumen-9.9.11.dmg" && said "refused the keys"
run fails "another bucket is not ours" env R2_BUCKET=someone-else scripts/r2_publish.sh --free "$BASE/Lumen-9.9.11.dmg"
run fails "an endpoint with the bucket in it is refused" env R2_ENDPOINT="https://127.0.0.1:$API/lumen-downloads" \
  scripts/r2_publish.sh --free "$BASE/Lumen-9.9.11.dmg" && said "with no bucket or path"
run fails "an address that is not https is refused" scripts/r2_publish.sh --free "http://127.0.0.1:$PUBLIC/Lumen-9.9.11.dmg"
run fails "a key with a quote in it never reaches curl's configuration" env R2_SECRET_ACCESS_KEY='abc"def' \
  scripts/r2_publish.sh --free "$BASE/Lumen-9.9.11.dmg" && said "a character no key has"

if grep -qF -- "$SECRET" "$T/curl-arguments" || grep -qF -- "$ID" "$T/curl-arguments"; then
  fail "a key was on curl's command line"
else
  pass "curl ran $(wc -l < "$T/curl-arguments" | tr -d ' ') times, never with a key in its arguments"
fi
grep -qF -- "$SECRET" "$T/all" && fail "the secret was printed" || pass "the secret was never printed"

if (( failures )); then echo "R2 PUBLISH TEST FAILED: $failures" >&2; exit 1; fi
echo "R2 PUBLISH TEST PASSED"
