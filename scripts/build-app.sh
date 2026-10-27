#!/usr/bin/env bash
# Builds PrivacyBrowser.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh                       # sandboxed release build → build/PrivacyBrowser.app
#   SANDBOX=0 scripts/build-app.sh             # hardened runtime without App Sandbox (debugging)
#   APP_DIR=build/variant scripts/build-app.sh # output directory
#   BUNDLE_ID=org.me.PB scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# With the packet-tunnel system extension (WebRTC through SOCKS5 proxies, docs/TUNNEL.md) —
# needs a paid Apple Developer team with the Network Extensions capability:
#   NE=1 TEAM_ID=ABCDE12345 SIGN_IDENTITY="Developer ID Application: … (ABCDE12345)" \
#     APP_PROFILE=path/app.provisionprofile EXTENSION_PROFILE=path/tunnel.provisionprofile \
#     scripts/build-app.sh
#   (EXTENSION_ID defaults to $BUNDLE_ID.PacketTunnel, APP_GROUP to $TEAM_ID.$BUNDLE_ID.
#   NE_SIGNING=development with an "Apple Development: …" identity and Development profiles,
#   for testing on a registered Mac; the default, developer-id, is what can be notarized.)
#   NE=check scripts/build-app.sh   # builds the extension and its bundle unsigned, for CI
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
NE="${NE:-0}"
EXTENSION_ID="${EXTENSION_ID:-$BUNDLE_ID.PacketTunnel}"
if [[ "$NE" == "1" ]]; then
  : "${TEAM_ID:?NE=1 needs TEAM_ID (your Apple Developer team)}"
  : "${APP_PROFILE:?NE=1 needs APP_PROFILE (the app's provisioning profile)}"
  : "${EXTENSION_PROFILE:?NE=1 needs EXTENSION_PROFILE (the extension's provisioning profile)}"
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: NE=1 needs SIGN_IDENTITY (ad-hoc signing cannot carry the entitlements)" >&2; exit 1; }
fi
TEAM_ID="${TEAM_ID:-XXXXXXXXXX}"
APP_GROUP="${APP_GROUP:-$TEAM_ID.$BUNDLE_ID}"
case "${NE_SIGNING:-developer-id}" in
  developer-id) NE_PROVIDER=packet-tunnel-provider-systemextension ;;
  development) NE_PROVIDER=packet-tunnel-provider ;;
  *) echo "error: NE_SIGNING is developer-id or development" >&2; exit 1 ;;
esac
EXTENSION_VERSION="${EXTENSION_VERSION:-$(date -u +%Y%m%d.%H%M%S)}"

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

# The app icon: the app draws its iconset from the Lumen mark (Sources/PrivacyBrowser/App/AppIcon.swift).
ICON_DIR="$(mktemp -d -t pbicon)"
"$BIN_DIR/PrivacyBrowser" --render-app-icon "$ICON_DIR/AppIcon.iconset" >/dev/null
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICON_DIR/AppIcon.iconset"
rm -rf "$ICON_DIR"

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

# The packet-tunnel system extension (NE=1: signed and embedded; NE=check: built and laid out
# beside the app, unsigned, so CI checks it compiles against the SDK and its plists are valid).
if [[ "$NE" == "1" || "$NE" == "check" ]]; then
  swift build -c "$CONFIG" --product PacketTunnelExtension
  if [[ "$NE" == "1" ]]; then
    SYSEXT="$APP/Contents/Library/SystemExtensions/$EXTENSION_ID.systemextension"
  else
    SYSEXT="$APP_DIR/$EXTENSION_ID.systemextension"
    rm -rf "$SYSEXT"
  fi
  mkdir -p "$SYSEXT/Contents/MacOS"
  cp "$BIN_DIR/PacketTunnelExtension" "$SYSEXT/Contents/MacOS/PacketTunnelExtension"
  sed -e "s/\$(EXTENSION_ID)/$EXTENSION_ID/g" -e "s/\$(APP_GROUP)/$APP_GROUP/g" -e "s/\$(EXTENSION_VERSION)/$EXTENSION_VERSION/g" \
    Resources/PacketTunnel/Info.plist > "$SYSEXT/Contents/Info.plist"
  plutil -lint "$SYSEXT/Contents/Info.plist" >/dev/null
  # NEProviderClasses names PacketTunnelExtension.PacketTunnelProvider: the Objective-C runtime
  # knows a Swift class by its mangled name, which must be in the binary.
  # (grep reads all of it: `grep -q` stopping early would fail the pipe under pipefail.)
  strings "$SYSEXT/Contents/MacOS/PacketTunnelExtension" | grep -x '_TtC21PacketTunnelExtension20PacketTunnelProvider' >/dev/null \
    || { echo "error: the extension has no PacketTunnelExtension.PacketTunnelProvider class" >&2; exit 1; }
  EXT_ENTITLEMENTS="$(mktemp -t pbtunnel).entitlements"
  sed -e "s/\$(EXTENSION_ID)/$EXTENSION_ID/g" -e "s/\$(APP_GROUP)/$APP_GROUP/g" -e "s/\$(TEAM_ID)/$TEAM_ID/g" \
    -e "s/\$(NE_PROVIDER)/$NE_PROVIDER/g" Resources/PacketTunnel/PacketTunnel.entitlements > "$EXT_ENTITLEMENTS"
  plutil -lint "$EXT_ENTITLEMENTS" >/dev/null
  if [[ "$NE" == "1" ]]; then
    cp "$EXTENSION_PROFILE" "$SYSEXT/Contents/embedded.provisionprofile"
    codesign --force --options runtime --timestamp --entitlements "$EXT_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$SYSEXT"
    cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
    # The app may install the extension and talks to it through the shared app group.
    ENTITLEMENTS_NE="$(mktemp -t pbapp).entitlements"
    cp "$ENTITLEMENTS" "$ENTITLEMENTS_NE"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.system-extension.install bool true" "$ENTITLEMENTS_NE"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.networking.networkextension array" \
      -c "Add :com.apple.developer.networking.networkextension:0 string $NE_PROVIDER" "$ENTITLEMENTS_NE"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
      -c "Add :com.apple.security.application-groups:0 string $APP_GROUP" "$ENTITLEMENTS_NE"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
      -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS_NE"
    ENTITLEMENTS="$ENTITLEMENTS_NE"
    /usr/libexec/PlistBuddy -c "Add :PBTunnelExtensionBundleIdentifier string $EXTENSION_ID" "$APP/Contents/Info.plist"
  fi
fi

TIMESTAMP="--timestamp=none"
[[ "$NE" != "1" ]] || TIMESTAMP="--timestamp"   # notarization needs a secure timestamp
codesign --force --options runtime "$TIMESTAMP" \
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
