#!/usr/bin/env bash
# scripts/download_json.py held to files it must take and files it must refuse (CI's Linux job; any
# machine with python3). The check reads the file's content, never the environment: CI's locale is
# English, where the release's old line wrote a dot, and the owner's Russian, where it wrote
# "sizeMB": 17,5 (3 November).
set -uo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/download-json.XXXXXX")"
trap 'rm -rf "$work"' EXIT
status=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; status=1; }

head -c 17512345 /dev/zero > "$work/Lumen-9.9.9.dmg"
write() {  # write <locale> <out>
  LC_ALL="$1" LANG="$1" python3 scripts/download_json.py write --dmg "$work/Lumen-9.9.9.dmg" --version 9.9.9 --build 99 \
    --url https://dl.lumenbrowser.io/Lumen-9.9.9.dmg --minimum-system 26.0 --out "$2" 2>&1
}
for locale in C en_US.UTF-8 ru_RU.UTF-8 de_DE.UTF-8; do
  write "$locale" "$work/$locale.json" >/dev/null
  if python3 scripts/download_json.py check "$work/$locale.json" --dmg "$work/Lumen-9.9.9.dmg" --minimum-system 26.0 >/dev/null \
     && grep -Eq '"sizeMB": 17\.5,' "$work/$locale.json"; then
    pass "written under LC_ALL=$locale: valid, \"sizeMB\": 17.5"
  else
    fail "written under LC_ALL=$locale: $(grep sizeMB "$work/$locale.json" 2>/dev/null)"
  fi
done

# The release's old line, under a locale that writes a decimal comma — said, where this machine has
# such a locale (CI's Linux image may have none).
old="$(LC_ALL=ru_RU.UTF-8 awk -v b=17512345 'BEGIN { printf "%.1f", b / 1000000 }' 2>/dev/null)"
echo "INFO the release's old line under LC_ALL=ru_RU.UTF-8 printed: $old"

refused() {  # refused <what> <text> [extra arguments to check]
  local name="$1" text="$2"; shift 2
  printf '%s' "$text" > "$work/case.json"
  if python3 scripts/download_json.py check "$work/case.json" "$@" > "$work/case.out" 2>&1; then
    fail "refused: $name — it was taken"
  else
    pass "refused: $name — $(head -n 1 "$work/case.out" | cut -c1-140)"
  fi
}
digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$work/Lumen-9.9.9.dmg")"
good() {  # the fields of a good file, one changed: good <name> <value as JSON>
  python3 - "$digest" "$1" "$2" <<'PY'
import json, sys
data = {"version": "9.9.9", "build": "99", "url": "https://dl.lumenbrowser.io/Lumen-9.9.9.dmg", "sizeMB": 17.5,
        "sizeBytes": 17512345, "sha256": sys.argv[1], "minimumSystem": "26.0"}
name, value = sys.argv[2], sys.argv[3]
if name:
    if value == "DELETE":
        del data[name]
    else:
        data[name] = json.loads(value)
print(json.dumps(data, indent=2))
PY
}
# 0.1.1's file on the owner's Mac, as it was written.
refused "0.1.1's file on a Mac whose locale writes a decimal comma (\"sizeMB\": 17,5)" "$(good "" "" | sed 's/"sizeMB": 17.5/"sizeMB": 17,5/')"
refused "NaN for a size" "$(good "" "" | sed 's/"sizeMB": 17.5/"sizeMB": NaN/')"
refused "the size as a string" "$(good sizeMB '"17,5"')"
refused "no SHA-256" "$(good sha256 DELETE)"
refused "a field the format has not" "$(good sizeKB 17512)"
refused "an address that is not https" "$(good url '"http://dl.lumenbrowser.io/Lumen-9.9.9.dmg"')"
refused "megabytes that are not the bytes" "$(good sizeMB 99.9)"
refused "another image's size" "$(good sizeBytes 17512346)" --dmg "$work/Lumen-9.9.9.dmg"
refused "another image's SHA-256" "$(good sha256 "\"$(printf '0%.0s' $(seq 1 64))\"")" --dmg "$work/Lumen-9.9.9.dmg"
refused "a macOS that is not the app's" "$(good minimumSystem '"14.0"')" --minimum-system 26.0
# And the good file itself is taken: the refusals above are for what each changed.
printf '%s' "$(good "" "")" > "$work/good.json"
python3 scripts/download_json.py check "$work/good.json" --dmg "$work/Lumen-9.9.9.dmg" --minimum-system 26.0 >/dev/null \
  && pass "the good file is taken" || fail "the good file was refused"
exit $status
