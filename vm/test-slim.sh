#!/bin/bash
# Regression checks for vm/slim.sh helpers that touch the filesystem.
# Run: bash vm/test-slim.sh
set -euo pipefail

SLIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slim.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# remove_glob must not word-split: a trashed "Old Downloads" once became
# `rm -rf Downloads`, relative to the current directory.
mkdir -p "$WORK/home/.Trash/Old Downloads" "$WORK/home/Downloads/keep" "$WORK/home/Old"
cd "$WORK/home"
# shellcheck disable=SC2034  # read by the eval'd remove_glob
DRY=0
eval "$(sed -n '/^remove_glob() {/,/^}/p' "$SLIM")"
remove_glob "" "$WORK/home/.Trash/"* >/dev/null
[[ ! -e "$WORK/home/.Trash/Old Downloads" ]] || { echo "FAIL: trashed folder kept"; exit 1; }
[[ -d "$WORK/home/Downloads/keep" && -d "$WORK/home/Old" ]] || { echo "FAIL: removed a folder outside the glob"; exit 1; }
remove_glob "" "$WORK/home/nothing-here/"* >/dev/null  # unmatched glob: no-op
echo "slim helper checks passed"
