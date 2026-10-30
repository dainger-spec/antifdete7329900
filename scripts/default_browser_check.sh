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
# the app's own entitlements and registered with LaunchServices. A measurement: it never fails.
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
copy="$scratch/PrivacyBrowser.app"
cp -R "$app" "$copy"
codesign -d --entitlements - --xml "$app" > "$out/entitlements.plist" 2>/dev/null
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleURLTypes array" \
  -c "Add :CFBundleURLTypes:0 dict" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLName string Web site URL" \
  -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string http" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string https" \
  -c "Add :CFBundleDocumentTypes array" \
  -c "Add :CFBundleDocumentTypes:0 dict" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Web page" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.html" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string public.xhtml" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:2 string public.url" \
  "$copy/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --entitlements "$out/entitlements.plist" --sign - "$copy" > "$out/codesign.txt" 2>&1 \
  || echo "::warning title=$title::the copy declared a browser could not be signed: $(tail -1 "$out/codesign.txt")"
"$lsregister" -f "$copy"
"$copy/Contents/MacOS/PrivacyBrowser" --default-browser-check > "$out/declared.txt" 2>/dev/null
echo "exit $?" >> "$out/declared.txt"
"$lsregister" -u "$copy" 2>/dev/null
rm -rf "$scratch"

for variant in as-built declared; do
  echo "--- $variant"
  cat "$out/$variant.txt"
  grep '^DEFAULT-BROWSER' "$out/$variant.txt" | cut -c1-500 | sed "s/^/::notice title=$title ($variant)::/"
done
exit 0
