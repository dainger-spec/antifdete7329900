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

# Optional per-profile packet-tunnel Network Extension (NE=1). Off by default: it needs a
# provisioning profile with the packet-tunnel-provider entitlement, which ad-hoc signing cannot
# grant, so CI and the ordinary build never touch it. See networkextension/README.md.
NE="${NE:-0}"
APP_FLAGS=()
if [[ "$NE" == "1" ]]; then
  : "${TEAM_ID:?NE=1 needs TEAM_ID (your 10-char Apple Developer Team ID)}"
  TUNNEL_BUNDLE_ID="${TUNNEL_BUNDLE_ID:-$BUNDLE_ID.PacketTunnel}"
  APP_GROUP="${APP_GROUP:-group.$BUNDLE_ID}"
  # Compile the app with the tunnel UI enabled.
  APP_FLAGS=(-Xswiftc -DPB_NETWORK_EXTENSION)
fi

# ${APP_FLAGS[@]+...} so an empty array doesn't trip `set -u` under the runner's bash 3.2.
swift build -c "$CONFIG" --product PrivacyBrowser ${APP_FLAGS[@]+"${APP_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PrivacyBrowser" "$APP/Contents/MacOS/PrivacyBrowser"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Localized strings into Bundle.main, where the app looks them up (see Localization.swift).
for lang in en ru; do
  cp -R "Resources/$lang.lproj" "$APP/Contents/Resources/$lang.lproj"
  plutil -lint "$APP/Contents/Resources/$lang.lproj/Localizable.strings" >/dev/null
done
if [[ "$SANDBOX" == "1" ]]; then
  sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/container-migration.plist > "$APP/Contents/Resources/container-migration.plist"
  plutil -lint "$APP/Contents/Resources/container-migration.plist" >/dev/null
fi

# Build, embed and sign the packet-tunnel extension before the app is signed (NE=1 only).
if [[ "$NE" == "1" ]]; then
  APPEX="$APP/Contents/PlugIns/PacketTunnel.appex"
  mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
  # The provider is not an SPM target; compile its sources straight into the appex binary.
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
  xcrun -sdk macosx swiftc -O -target arm64-apple-macos14.0 -sdk "$SDK" \
    -module-name PacketTunnel -parse-as-library \
    networkextension/PacketTunnelProvider.swift networkextension/Relay.swift \
    -framework NetworkExtension -o "$APPEX/Contents/MacOS/PacketTunnel"
  sed -e "s/\$(TUNNEL_BUNDLE_ID)/$TUNNEL_BUNDLE_ID/g" -e "s/\$(PRODUCT_MODULE_NAME)/PacketTunnel/g" \
    networkextension/Info.plist > "$APPEX/Contents/Info.plist"
  plutil -lint "$APPEX/Contents/Info.plist" >/dev/null
  NE_ENTITLEMENTS="$(mktemp)"
  sed "s/\$(APP_GROUP)/$APP_GROUP/g" networkextension/PacketTunnel.entitlements > "$NE_ENTITLEMENTS"
  codesign --force --options runtime --timestamp=none \
    --entitlements "$NE_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APPEX"
  echo "Embedded $APPEX (tunnel bundle id $TUNNEL_BUNDLE_ID)"
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
