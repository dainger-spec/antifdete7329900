#!/usr/bin/env bash
# Builds PrivacyBrowser.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh                 # release build, ad-hoc signed, ./build/PrivacyBrowser.app
#   BUNDLE_ID=org.me.PB scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Requires macOS 14+ and Xcode 15+ (or the matching Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-dev.local.PrivacyBrowser}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
CONFIG="${CONFIG:-release}"
APP="build/PrivacyBrowser.app"

swift build -c "$CONFIG" --product PrivacyBrowser
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PrivacyBrowser" "$APP/Contents/MacOS/PrivacyBrowser"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/PrivacyBrowser.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (bundle id $BUNDLE_ID)"
echo "Run:   open $APP"
