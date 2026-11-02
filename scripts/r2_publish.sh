#!/usr/bin/env bash
# Publishes a release's file in the Cloudflare R2 bucket behind dl.lumenbrowser.io, and proves it:
# the file is read back from its public address and its SHA-256 compared with the built one. What
# is served there must be, byte for byte, what was built; anything else is a failed release
# (docs/UPDATES.md §6, "Uploaded"). scripts/release.sh runs it; it runs on macOS and Linux.
#
#   scripts/r2_publish.sh FILE PUBLIC_URL CONTENT_TYPE CACHE_CONTROL [--replace]
#       uploads FILE under PUBLIC_URL's path, then reads PUBLIC_URL and compares
#   scripts/r2_publish.sh --free PUBLIC_URL
#       fails if the bucket already holds PUBLIC_URL's name (and so checks the keys before a build)
#   scripts/r2_publish.sh --current PUBLIC_URL FILE
#       saves the object PUBLIC_URL names into FILE, read from the bucket; none there yet leaves no
#       FILE and is not an error (the appcast before the first release)
#
# R2's keys come from the environment only: R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com,
# no bucket), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_BUCKET (default lumen-downloads). They
# reach curl on its standard input, never on its command line, which ps shows every user of the
# Mac. curl signs the requests itself (SigV4, nothing to install), and sends the file's SHA-256 as
# x-amz-content-sha256, so R2 refuses an upload that did not arrive as the file is.
#
# A versioned file is never replaced: if its name is taken with other bytes the script stops — people
# downloaded those, the website names their SHA-256, and Cloudflare keeps them cached for a year. The
# same bytes are left as they are and only read back, so a publication that failed is tried again by
# running this again on the same files. --replace is for the appcast, which every release rewrites.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
usage() {
  echo "usage: $0 FILE PUBLIC_URL CONTENT_TYPE CACHE_CONTROL [--replace]" >&2
  echo "       $0 --free PUBLIC_URL" >&2
  echo "       $0 --current PUBLIC_URL FILE" >&2
  exit 2
}
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
header() { tr -d '\r' < "$1" | awk -v name="$2" 'BEGIN { FS = ": *" } tolower($1) == name { value = $2 } END { print value }'; }

keys() {
  : "${R2_ENDPOINT:?R2_ENDPOINT is needed (https://<account>.r2.cloudflarestorage.com)}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is needed}" "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is needed}"
  R2_BUCKET="${R2_BUCKET:-lumen-downloads}"
  local endpoint='^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$' bucket='^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' key='^[A-Za-z0-9+/=_-]+$'
  [[ "$R2_ENDPOINT" =~ $endpoint ]] \
    || die "R2_ENDPOINT must be the account's endpoint, https://<account>.r2.cloudflarestorage.com, with no bucket or path"
  [[ "$R2_BUCKET" =~ $bucket ]] || die "R2_BUCKET '$R2_BUCKET' is not a bucket's name"
  # Only what keys are made of: nothing that could end curl's configuration line.
  [[ "$R2_ACCESS_KEY_ID" =~ $key && "$R2_SECRET_ACCESS_KEY" =~ $key ]] \
    || die "R2_ACCESS_KEY_ID or R2_SECRET_ACCESS_KEY holds a character no key has"
}

# curl, signed for R2. The keys go in on curl's standard input as its configuration (`user`), so
# they are in no process's arguments; printf is the shell's own.
r2() {
  printf 'user = "%s:%s"\n' "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" \
    | curl --config - --aws-sigv4 "aws:amz:auto:s3" --tlsv1.2 --silent --show-error "$@"
}

# The object's name is the public address's path; only names that need no encoding.
name_of() {
  local address='^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-][A-Za-z0-9._/-]*$'
  [[ "$1" =~ $address ]] \
    || die "$1 is not an https address of a file (letters, digits, . _ - / in its path)"
  local rest="${1#https://}"
  echo "${rest#*/}"
}
object_url() { echo "${R2_ENDPOINT%/}/$R2_BUCKET/$1"; }

# The bucket's answer for a name: its HTTP status, the headers in $TMP/head.
status_of() {
  r2 --head --output /dev/null --dump-header "$TMP/head" --write-out '%{http_code}' "$(object_url "$1")" \
    || die "R2 could not be reached at $R2_ENDPOINT"
}
refused() { die "R2 refused the keys ($1 for $R2_BUCKET/$2): R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY need Object Read & Write on $R2_BUCKET"; }

free() {
  local name code
  name="$(name_of "$1")"
  code="$(status_of "$name")"
  case "$code" in
    404) echo "$name: free in $R2_BUCKET" ;;
    200) die "$name is already published in $R2_BUCKET: a published version is never replaced — this release needs a new VERSION" ;;
    401|403) refused "$code" "$name" ;;
    *) die "R2 answered $code for $R2_BUCKET/$name" ;;
  esac
}

current() {
  local name code
  name="$(name_of "$1")"
  code="$(r2 --output "$TMP/current" --write-out '%{http_code}' "$(object_url "$name")")" \
    || die "R2 could not be reached at $R2_ENDPOINT"
  case "$code" in
    200) mv "$TMP/current" "$2"; echo "$name: the one published now, $(( $(wc -c < "$2") )) bytes, kept for this release's" ;;
    404) rm -f "$2"; echo "$name: none in $R2_BUCKET yet" ;;
    401|403) refused "$code" "$name" ;;
    *) die "R2 answered $code for $R2_BUCKET/$name" ;;
  esac
}

publish() {
  local file="$1" url="$2" type="$3" cache="$4" replace="$5" name sha size code there got got_size status
  [[ -f "$file" ]] || die "$file: no such file"
  name="$(name_of "$url")"
  sha="$(sha256 "$file")"
  size=$(( $(wc -c < "$file") ))
  code="$(status_of "$name")"
  case "$code" in
    404) there="" ;;
    200) there="$(header "$TMP/head" x-amz-meta-sha256)"
         [[ "$there" == "$sha" || "$replace" == 1 ]] \
           || die "$name is already published with other bytes (sha256 ${there:-not recorded}): a published version is never replaced. Release a new VERSION — or, knowing people may have it, delete $name from $R2_BUCKET and purge it from Cloudflare's cache first" ;;
    401|403) refused "$code" "$name" ;;
    *) die "R2 answered $code for $R2_BUCKET/$name" ;;
  esac
  if [[ "$there" == "$sha" ]]; then
    echo "$name: in $R2_BUCKET already, the same bytes"
  else
    r2 --fail --retry 3 --retry-delay 5 --output /dev/null \
      -H "Content-Type: $type" -H "Cache-Control: $cache" \
      -H "x-amz-meta-sha256: $sha" -H "x-amz-content-sha256: $sha" \
      --upload-file "$file" "$(object_url "$name")" \
      || die "$name: the upload to R2 failed"
  fi
  # Read back as anyone reads it: the public address, through Cloudflare.
  code="$(curl --tlsv1.2 --silent --show-error --retry 3 --retry-delay 5 -H 'Cache-Control: no-cache' \
    --dump-header "$TMP/get" --output "$TMP/body" --write-out '%{http_code}' "$url")" \
    || die "$url could not be read back: the release has failed"
  [[ "$code" == 200 ]] || die "$url answered $code where $(basename "$file") was just published: the release has failed"
  got="$(sha256 "$TMP/body")"
  got_size=$(( $(wc -c < "$TMP/body") ))
  rm -f "$TMP/body"
  if [[ "$got" != "$sha" ]]; then
    status="$(header "$TMP/get" cf-cache-status)"
    [[ -z "$status" ]] || status=" (Cloudflare's cache: $status)"
    die "$url serves other bytes than $(basename "$file"): sha256 $got, $got_size bytes, where the build is sha256 $sha, $size bytes$status. The release has failed"
  fi
  echo "$(basename "$file"): published at $url and read back — sha256 $sha, $size bytes, the same"
}

[[ $# -ge 1 ]] || usage
TMP="$(mktemp -d "${TMPDIR:-/tmp}/r2-publish.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
case "$1" in
  --free) [[ $# -eq 2 ]] || usage; keys; free "$2" ;;
  --current) [[ $# -eq 3 ]] || usage; keys; current "$2" "$3" ;;
  -*) usage ;;
  *) [[ $# -eq 4 || ( $# -eq 5 && "${5:-}" == --replace ) ]] || usage
     keys
     publish "$1" "$2" "$3" "$4" "$([[ "${5:-}" == --replace ]] && echo 1 || echo 0)" ;;
esac
