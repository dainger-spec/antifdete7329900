#!/usr/bin/env bash
# The release check's verdict as release.sh takes it. The app's --release-check (ReleaseCheck.swift)
# prints a line per check — RELEASE-CHECK PASS, FAIL or INFO — and exits 1 at the first FAIL. A
# release only when the app exited 0, no line says FAIL, and one says the profile's window was
# Safari's own, in a process of its own. The keychain between profiles is checked after that window:
# its FAIL stops the release as any other does — one PASS among the lines is not the check passed.
#
#   scripts/release_check_gate.sh <the release check's output, a file> <its exit status>
#
# Exits 0 for a release, 1 (with the reason) for none. CI holds it to outputs made up for the
# purpose, each with the verdict it must give (ci.yml, "The release gate reads every line").
set -uo pipefail

# (No apostrophe in these words: inside "${…:?…}" bash takes one as a quote.)
output="${1:?usage: release_check_gate.sh <output of the release check> <its exit status>}"
status="${2:?usage: release_check_gate.sh <output of the release check> <its exit status>}"

if [[ ! -r "$output" ]]; then
  echo "release gate: no output to read at $output" >&2
  exit 1
fi
if [[ "$status" != "0" ]]; then
  echo "release gate: the release check exited $status" >&2
  exit 1
fi
if grep -q '^RELEASE-CHECK FAIL' "$output"; then
  echo "release gate: $(grep -m 1 '^RELEASE-CHECK FAIL' "$output" | cut -c 1-300)" >&2
  exit 1
fi
if ! grep -q '^RELEASE-CHECK PASS a profile in a process of its own' "$output"; then
  echo "release gate: no line says a profile came up in a process of its own, in Safari's own window" >&2
  exit 1
fi
exit 0
