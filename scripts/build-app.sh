#!/usr/bin/env bash
# Builds PrivacyBrowser.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh                       # sandboxed release build → build/PrivacyBrowser.app
#   SANDBOX=0 scripts/build-app.sh             # hardened runtime without App Sandbox (debugging)
#   APP_DIR=build/variant scripts/build-app.sh # output directory
#   BUNDLE_ID=org.me.PB scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Requires macOS 14+ and Xcode 15+ (or the matching Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-dev.local.PrivacyBrowser}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
CONFIG="${CONFIG:-release}"
SANDBOX="${SANDBOX:-1}"
APP_DIR="${APP_DIR:-build}"
APP="$APP_DIR/PrivacyBrowser.app"

if [[ "$SANDBOX" == "1" ]]; then
  ENTITLEMENTS=Resources/PrivacyBrowser.entitlements
else
  ENTITLEMENTS=Resources/PrivacyBrowser-NoSandbox.entitlements
fi

swift build -c "$CONFIG" --product PrivacyBrowser
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PrivacyBrowser" "$APP/Contents/MacOS/PrivacyBrowser"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The fingerprint probe the self-test and scripts/safari_reference.py share.
cp Resources/fingerprint_probe.js "$APP/Contents/Resources/fingerprint_probe.js"

# Localized strings into Bundle.main, where the app looks them up (see Localization.swift).
for lang in en ru; do
  cp -R "Resources/$lang.lproj" "$APP/Contents/Resources/$lang.lproj"
  plutil -lint "$APP/Contents/Resources/$lang.lproj/Localizable.strings" >/dev/null
done
if [[ "$SANDBOX" == "1" ]]; then
  sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/container-migration.plist > "$APP/Contents/Resources/container-migration.plist"
  plutil -lint "$APP/Contents/Resources/container-migration.plist" >/dev/null
fi

codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Fail loudly if the signature does not carry the expected sandbox state.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  [[ "$SANDBOX" == "1" ]] || { echo "error: unexpected sandbox entitlement" >&2; exit 1; }
  echo "Built $APP (bundle id $BUNDLE_ID, App Sandbox ON)"
else
  [[ "$SANDBOX" != "1" ]] || { echo "error: sandbox entitlement missing from signature" >&2; exit 1; }
  echo "Built $APP (bundle id $BUNDLE_ID, App Sandbox OFF)"
fi
echo "Run:        open $APP"
echo "Self-test:  $APP/Contents/MacOS/PrivacyBrowser --self-test"
