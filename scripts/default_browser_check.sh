#!/bin/bash
# Does Safari's own question about the default browser (-[GeneralPreferences
# _defaultWebBrowserMayHaveChanged]) throw in a profile's process of this app — it threw on a nil
# when ⌘, opened Safari's settings in a profile's window — and is that because the app is not a
# browser as far as the system knows? (SafariChrome.runDefaultBrowserCheck)
#
#   scripts/default_browser_check.sh <PrivacyBrowser.app> <out dir> <notice title>
#
# Runs the check on the app as built, then on a copy that declares itself a browser — the http and
# https schemes and the web's document types, as a browser's Info.plist does — signed ad hoc with
# the app's own entitlements and registered with LaunchServices. The copy's Info.plist is edited
# with Python's plistlib (PlistBuddy aborted on macOS 27 and left it as built), and the declared run
# is said to count only when LaunchServices lists the copy among http's handlers. A measurement: it
# never fails.
set -u
app="$1"
out="$2"
title="$3"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$out"

"$app/Contents/MacOS/PrivacyBrowser" --default-browser-check > "$out/as-built.txt" 2>/dev/null
echo "exit $?" >> "$out/as-built.txt"

# The copy goes in a temporary folder of its own, not with the results (which CI keeps).
scratch="$(mktemp -d)"
if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "::warning title=$title::no temporary folder for the copy declared a browser"
  exit 0
fi
copy="$scratch/PrivacyBrowser.app"
cp -R "$app" "$copy"
codesign -d --entitlements - --xml "$app" > "$out/entitlements.plist" 2>/dev/null
if python3 - "$copy/Contents/Info.plist" > "$out/declared-plist.txt" 2>&1 <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
info["CFBundleURLTypes"] = info.get("CFBundleURLTypes", []) + [{
    "CFBundleURLName": "Web site URL",
    "CFBundleTypeRole": "Viewer",
    "CFBundleURLSchemes": ["http", "https"],
}]
info["CFBundleDocumentTypes"] = info.get("CFBundleDocumentTypes", []) + [{
    "CFBundleTypeName": "Web page",
    "CFBundleTypeRole": "Viewer",
    "LSItemContentTypes": ["public.html", "public.xhtml", "public.url"],
}]
with open(path, "wb") as f:
    plistlib.dump(info, f)
# What the file says now, read back from it.
with open(path, "rb") as f:
    info = plistlib.load(f)
print("schemes:", [s for t in info.get("CFBundleURLTypes", []) for s in t.get("CFBundleURLSchemes", [])])
print("document types:", [c for t in info.get("CFBundleDocumentTypes", []) for c in t.get("LSItemContentTypes", [])])
PY
then
  codesign --force --options runtime --timestamp=none --entitlements "$out/entitlements.plist" --sign - "$copy" > "$out/codesign.txt" 2>&1 \
    || echo "::warning title=$title::the copy declared a browser could not be signed: $(tail -1 "$out/codesign.txt")"
  "$lsregister" -f "$copy"
  "$copy/Contents/MacOS/PrivacyBrowser" --default-browser-check > "$out/declared.txt" 2>/dev/null
  echo "exit $?" >> "$out/declared.txt"
  "$lsregister" -u "$copy" 2>/dev/null
else
  echo "::warning title=$title::the copy's Info.plist could not be edited: $(tail -1 "$out/declared-plist.txt")"
  echo "not run: the copy's Info.plist could not be edited" > "$out/declared.txt"
fi
rm -rf "$scratch"

echo "--- the copy's Info.plist"
cat "$out/declared-plist.txt"
for variant in as-built declared; do
  echo "--- $variant"
  cat "$out/$variant.txt"
  grep '^DEFAULT-BROWSER' "$out/$variant.txt" | cut -c1-500 | sed "s/^/::notice title=$title ($variant)::/"
done
# The declared run tests the question only if the system took the copy for an http handler.
if ! grep -q '^DEFAULT-BROWSER http: .*among them: true' "$out/declared.txt"; then
  echo "::warning title=$title::LaunchServices did not list the copy among http's handlers: the declared run does not say whether being a browser matters"
fi
exit 0
