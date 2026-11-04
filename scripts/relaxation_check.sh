#!/usr/bin/env bash
# No executable of the app holds a relaxation of the hardened runtime beside the network extension's
# right (com.apple.developer.networking.networkextension): the kernel kills such an executable at its
# start. Exit 1 naming each one that does and what it holds; read from the signatures themselves, key
# by key (a comment or a string that names a key is not the key).
#
#   scripts/relaxation_check.sh <Lumen.app>
#
# Measured on 3 November 2026 on the owner's Mac — macOS 27.0.1 (26A434), Developer ID signatures,
# scripts/amfi_matrix.py; the table is in docs/TUNNEL.md, "What the kernel kills". 0.1.1 with the
# network guard, notarized, was killed at its start ("Hardened Runtime relaxation entitlements
# disallowed on System Extensions"): its app's executable held disable-library-validation beside that
# right. Killed beside the right: each of the three relaxations in MEASURED, with or without the right
# to install a system extension, with or without the extension in the bundle. Started: the same
# executable without the relaxation, with allow-jit instead of it, and with it but without the right.
#
# build-app.sh runs this on every build it signs and removes a build it refuses; release.sh again on
# what it is about to notarize. CI holds it to copies it must refuse and to copies it must let through.
set -uo pipefail
app="${1:?usage: relaxation_check.sh <Lumen.app>}"
app="${app%/}"
[[ -f "$app/Contents/Info.plist" ]] || { echo "error: $app is not an app bundle" >&2; exit 1; }

RIGHT=com.apple.developer.networking.networkextension
# Killed at its start beside the right: measured (above).
MEASURED=(com.apple.security.cs.disable-library-validation
          com.apple.security.cs.allow-unsigned-executable-memory
          com.apple.security.cs.allow-dyld-environment-variables)
# Not measured, refused all the same: the hardened runtime's other exceptions that relax what it
# protects. Refusing one costs nothing; letting one through beside the right would be a guess.
UNMEASURED=(com.apple.security.cs.disable-executable-page-protection
            com.apple.security.cs.debugger)
# Not in either list: com.apple.security.cs.allow-jit. Measured: the app's executable holding it
# beside the right started (copy app-jit). Nothing of the app's asks for it.

# held <entitlements plist> <key>: the signature carries the key — with any value: whether the kernel
# takes a relaxation set to false as absent is not measured, so it is not taken so here.
held() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1
}

main_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)"
work="$(mktemp -d "${TMPDIR:-/tmp}/pbrelaxation.XXXXXX")" || { echo "error: no temporary folder" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
count=0
names=""
holders=""
paired=0
unreadable=0
main_read=0
while IFS= read -r -d '' file; do
  kind="$(file -b "$file" 2>/dev/null)"
  [[ "$kind" == *Mach-O* ]] || continue
  name="${file#"$app"/}"
  plist="$work/$count.plist"
  if ! codesign -d --entitlements - --xml "$file" > "$plist" 2> "$work/error"; then
    echo "error: $name: its signature cannot be read ($(head -n 1 "$work/error"))" >&2
    unreadable=1
    continue
  fi
  count=$((count + 1))
  names+="${names:+, }${name##*/}"
  # The reading's own control: the camera entitlement the app's executable is signed with in every
  # build. A reading that does not show it shows nothing, and this check would pass on nothing.
  if [[ "$name" == "Contents/MacOS/$main_name" ]] && held "$plist" com.apple.security.device.camera; then main_read=1; fi
  # Signed without entitlements (the updater's helper): it holds neither.
  [[ -s "$plist" ]] || continue
  held "$plist" "$RIGHT" || continue
  holders+="${holders:+, }$name"
  for key in "${MEASURED[@]}"; do
    if held "$plist" "$key"; then
      echo "error: $name holds $key beside $RIGHT: the kernel kills it at its start (measured on macOS 27.0.1, docs/TUNNEL.md)" >&2
      paired=1
    fi
  done
  for key in "${UNMEASURED[@]}"; do
    if held "$plist" "$key"; then
      echo "error: $name holds $key beside $RIGHT: not measured, refused as the measured relaxations are" >&2
      paired=1
    fi
  done
done < <(find "$app" -type f -perm -u+x -print0)

if [[ "$main_read" != 1 ]]; then
  echo "error: the app's executable (Contents/MacOS/$main_name) showed no entitlements: the signatures were not read, and nothing is checked" >&2
  exit 1
fi
if [[ "$unreadable" != 0 ]]; then
  echo "error: refused: an executable of the app whose signature cannot be read is not checked, and is not let through" >&2
fi
if [[ "$paired" != 0 ]]; then
  echo "error: refused: an executable that holds $RIGHT holds none of ${MEASURED[*]} (measured: killed) or ${UNMEASURED[*]} (not measured); com.apple.security.cs.allow-jit is not among them (measured: started)" >&2
fi
[[ "$unreadable" == 0 && "$paired" == 0 ]] || exit 1
echo "relaxation check: $count executables read ($names); $RIGHT held by ${holders:-none of them}, and no relaxation beside it"
