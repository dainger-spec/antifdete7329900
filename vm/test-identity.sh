#!/bin/bash
# Off-Mac checks for vm/identity.sh: `--print` mode only, nothing is changed.
# Run: bash vm/test-identity.sh
set -euo pipefail

ID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/identity.sh"
FAILS=0

check() { # <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAILS=$((FAILS + 1)); fi
}
field() { bash "$ID" --print -- "$2" | sed -n "s/^$1=//p"; }

# Same name → same MAC, every run.
check "MAC is deterministic" "$(field MAC work)" "$(field MAC work)"
# Pinned value: sha256("work") starts with 00e13e — catches a change of hash
# input (e.g. a trailing newline from `echo`) that would move every profile's MAC.
check "MAC pinned for 'work'" "$(field MAC work)" "3C:22:FB:00:E1:3E"
check "different names differ" "$([[ "$(field MAC work)" != "$(field MAC home)" ]] && echo yes)" "yes"
check "MAC format" "$(field MAC 'any name' | grep -cE '^3C:22:FB(:[0-9A-F]{2}){3}$')" "1"

check "hostname" "$(field HOSTNAME work)" "Mac-work"
check "hostname drops spaces/punctuation" "$(field HOSTNAME 'my work!')" "Mac-mywork"
check "hostname trims hyphens" "$(field HOSTNAME '--a-b--')" "Mac-a-b"
check "hostname capped at Mac- + 20" "$(field HOSTNAME 'abcdefghijklmnopqrstuvwxyz')" "Mac-abcdefghijklmnopqrst"
CYR="$(field HOSTNAME 'Работа')"
check "non-ASCII name gets a stable hash tag" "$(grep -cE '^Mac-[0-9a-f]{8}$' <<< "$CYR")" "1"
check "non-ASCII names stay distinct" "$([[ "$CYR" != "$(field HOSTNAME 'Дом')" ]] && echo yes)" "yes"
check "name '-e' after -- is hashed, not dropped" "$(field MAC -e | grep -cE '^3C:22:FB')" "1"

# Time zone and language (printed only; applied inside the guest).
TZL="$(bash "$ID" --print --timezone Europe/Berlin --language de-DE -- work)"
check "time zone passed through" "$(sed -n 's/^TIMEZONE=//p' <<< "$TZL")" "Europe/Berlin"
check "language → locale" "$(sed -n 's/^LOCALE=//p' <<< "$TZL")" "de_DE"
check "bare language keeps region" "$(bash "$ID" --print --language pt -- w | grep -c '^LOCALE=' || true)" "0"

# Usage errors.
set +e
bash "$ID" --print --timezone ../../etc/passwd w >/dev/null 2>&1; check "path-like time zone refused" "$?" "1"
bash "$ID" --print --timezone 'Europe/Berlin;id' w >/dev/null 2>&1; check "shell-ish time zone refused" "$?" "1"
bash "$ID" --print --language 'de;rm' w >/dev/null 2>&1; check "shell-ish language refused" "$?" "1"
bash "$ID" --print --timezone >/dev/null 2>&1; check "--timezone without value refused" "$?" "1"
bash "$ID" >/dev/null 2>&1; check "no name → exit 1" "$?" "1"
# Off a Mac there is no kern.hv_vmm_present, so it must refuse before scutil.
# Not run on macOS: a CI runner or dev Mac may itself be a VM and get renamed.
if [[ "$(uname)" != Darwin ]]; then
  bash "$ID" work >/dev/null 2>&1; check "not a VM → exit 2" "$?" "2"
fi
set -e

# The controller's form: script on stdin, name quoted with %q for the guest shell.
VIA_STDIN="$(bash -c "bash -s -- --print $(printf '%q' 'my work')" < "$ID" | sed -n 's/^HOSTNAME=//p')"
check "bash -s with a %q-quoted name" "$VIA_STDIN" "Mac-mywork"

[[ $FAILS -eq 0 ]] && echo "all identity checks passed" || { echo "$FAILS failed"; exit 1; }
