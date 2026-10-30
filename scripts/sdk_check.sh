#!/bin/bash
# What follows the SDK an app's executable declares (SDKCheck, in SDKBehaviors.swift): the app as
# built, and a copy whose executable declares another SDK — this Xcode's own, in CI — each run with
# WebKit's behaviors as its SDK gives them and with every one on, as Safari has them (--everything).
# It shows whether window.trustedTypes and the window's other interfaces (by name), and the screen's
# visible frame (screen.availHeight), follow the SDK, and whether WebKit's switch puts a page where
# Safari's is. Given a folder, it also renders the app's screens from both (--render-ui-snapshots, in
# English, into as-built/ and sdk-<SDK>/): what AppKit draws differently for each SDK.
#
#   scripts/sdk_check.sh <PrivacyBrowser.app> <out dir> <notice title> <SDK for the copy> [<snapshots dir>]
#
# The copy's LC_BUILD_VERSION is rewritten with Xcode's vtool (its minos kept) and the copy signed ad
# hoc with the app's own entitlements, in a temporary folder of its own. A measurement: it never fails.
set -u
app="$1"
out="$2"
title="$3"
sdk="$4"
snapshots="${5:-}"
binary="Contents/MacOS/PrivacyBrowser"
mkdir -p "$out"

# <app> <name> [--everything]
run() {
  "$1/$binary" --sdk-check ${3:-} > "$out/$2.txt" 2>/dev/null
  echo "exit $?" >> "$out/$2.txt"
}

xcrun vtool -show-build "$app/$binary" > "$out/build-version.txt" 2>&1
minos="$(awk '$1 == "minos" { print $2; exit }' "$out/build-version.txt")"
declared="$(awk '$1 == "sdk" { print $2; exit }' "$out/build-version.txt")"
echo "::notice title=$title::the app as built declares minos ${minos:-?}, sdk ${declared:-?}; this Xcode's SDK is $(xcrun --show-sdk-version 2>/dev/null); the copy declares sdk $sdk"

run "$app" as-built
run "$app" as-built-everything --everything

scratch="$(mktemp -d)"
if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "::warning title=$title::no temporary folder for the copy that declares SDK $sdk"
  exit 0
fi
copy="$scratch/PrivacyBrowser.app"
cp -R "$app" "$copy"
if [ -n "$minos" ] && xcrun vtool -set-build-version macos "$minos" "$sdk" -replace -output "$copy/$binary.declared" "$copy/$binary" > "$out/vtool.txt" 2>&1; then
  mv "$copy/$binary.declared" "$copy/$binary"
  xcrun vtool -show-build "$copy/$binary" > "$out/build-version-copy.txt" 2>&1
  codesign -d --entitlements - --xml "$app" > "$out/entitlements.plist" 2>/dev/null
  codesign --force --options runtime --timestamp=none --entitlements "$out/entitlements.plist" --sign - "$copy" > "$out/codesign.txt" 2>&1 \
    || echo "::warning title=$title::the copy that declares SDK $sdk could not be signed: $(tail -1 "$out/codesign.txt")"
  run "$copy" "sdk-$sdk"
  run "$copy" "sdk-$sdk-everything" --everything
  if [ -n "$snapshots" ]; then
    mkdir -p "$snapshots/as-built" "$snapshots/sdk-$sdk"
    snapshots="$(cd "$snapshots" && pwd)"
    for side in "as-built:$app" "sdk-$sdk:$copy"; do
      name="${side%%:*}" bundle="${side#*:}"
      PRIVACYBROWSER_LANG=en "$bundle/$binary" --render-ui-snapshots "$snapshots/$name/en" > "$snapshots/$name/en.log" 2>&1 \
        || echo "::warning title=$title::$name did not render every screen: $(tail -1 "$snapshots/$name/en.log")"
    done
  fi
else
  echo "::warning title=$title::the copy's build version could not be set (minos '$minos'): $(tail -1 "$out/vtool.txt")"
fi
rm -rf "$scratch"

# Each run's own lines, then the window's own properties that differ from the build as made.
names() {
  grep '^SDK-CHECK window names: ' "$out/$1.txt" | sed 's/^SDK-CHECK window names: //' | tr ',' '\n' | sed '/^$/d' | sort > "$out/$1.names"
}
names as-built
for variant in as-built as-built-everything "sdk-$sdk" "sdk-$sdk-everything"; do
  [ -f "$out/$variant.txt" ] || continue
  echo "--- $variant"
  grep -v '^SDK-CHECK window names: ' "$out/$variant.txt"
  grep '^SDK-CHECK' "$out/$variant.txt" | grep -v '^SDK-CHECK window names: ' | cut -c1-500 | sed "s/^/::notice title=$title ($variant)::/"
  [ "$variant" = as-built ] && continue
  names "$variant"
  added="$(comm -13 "$out/as-built.names" "$out/$variant.names" | tr '\n' ' ')"
  removed="$(comm -23 "$out/as-built.names" "$out/$variant.names" | tr '\n' ' ')"
  echo "SDK-CHECK window names, $variant against the build as made: added (${added:-none}); gone (${removed:-none})" \
    | tee -a "$out/names-diff.txt" | cut -c1-900 | sed "s/^/::notice title=$title ($variant)::/"
done
exit 0
