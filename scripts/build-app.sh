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
# Versions and updates (docs/UPDATES.md; scripts/release.sh sets these):
#   APP_VERSION=0.2.0 APP_BUILD=2      CFBundleShortVersionString and CFBundleVersion
#   UPDATE_FEED_URL=https://…/appcast.json UPDATE_PUBLIC_KEYS="<key id>=<base64>,…" [UPDATE_TEAM_ID=…]
#                                      the app checks for updates (without a feed URL it has no updater)
#   WEBSITE_URL=https://… SUPPORT_URL=https://…   the links Settings → About shows (none without them)
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
# The sandboxed entitlements name the update's staging folder by the bundle id.
ENTITLEMENTS_BUILT="$(mktemp -t pbentitlements).entitlements"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" "$ENTITLEMENTS" > "$ENTITLEMENTS_BUILT"
plutil -lint "$ENTITLEMENTS_BUILT" >/dev/null
ENTITLEMENTS="$ENTITLEMENTS_BUILT"

swift build -c "$CONFIG" --product PrivacyBrowser
swift build -c "$CONFIG" --product PrivacyBrowserUpdater
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PrivacyBrowser" "$APP/Contents/MacOS/PrivacyBrowser"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/Info.plist > "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
[[ -z "${APP_VERSION:-}" ]] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST"
[[ -z "${APP_BUILD:-}" ]] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$PLIST"
# What the app trusts for updates (docs/UPDATES.md §2): the feed, the keys of its signatures, and
# the Team ID an update must be signed by. Checked again by the app and its installer.
if [[ -n "${UPDATE_FEED_URL:-}" ]]; then
  [[ "$UPDATE_FEED_URL" == https://* ]] || { echo "error: UPDATE_FEED_URL must be https" >&2; exit 1; }
  [[ -n "${UPDATE_PUBLIC_KEYS:-}" ]] || { echo "error: UPDATE_FEED_URL needs UPDATE_PUBLIC_KEYS" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :PBUpdateFeedURL string $UPDATE_FEED_URL" "$PLIST"
fi
if [[ -n "${UPDATE_PUBLIC_KEYS:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :PBUpdatePublicKeys dict" "$PLIST"
  IFS=',' read -ra UPDATE_KEYS <<< "$UPDATE_PUBLIC_KEYS"
  for entry in "${UPDATE_KEYS[@]}"; do
    id="${entry%%=*}"
    key="${entry#*=}"
    [[ "$id" =~ ^[0-9a-f]{16}$ && -n "$key" && "$key" != "$entry" ]] \
      || { echo "error: UPDATE_PUBLIC_KEYS: '$entry' is not <key id>=<base64>" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :PBUpdatePublicKeys:$id string $key" "$PLIST"
  done
fi
[[ -z "${UPDATE_TEAM_ID:-}" ]] || /usr/libexec/PlistBuddy -c "Add :PBUpdateTeamID string $UPDATE_TEAM_ID" "$PLIST"
# Settings → About links to these; https only, as the app reads them.
for link in "WEBSITE_URL:PBWebsiteURL" "SUPPORT_URL:PBSupportURL"; do
  variable="${link%%:*}" key="${link#*:}"
  value="${!variable:-}"
  [[ -z "$value" ]] && continue
  [[ "$value" == https://* ]] || { echo "error: $variable must be https" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST"
done
plutil -lint "$PLIST" >/dev/null

# The installer helper (docs/UPDATES.md §3): an app of its own, outside the sandbox, that the app
# starts through LaunchServices at the end of a quit in which every profile was sealed.
HELPER="$APP/Contents/Helpers/PrivacyBrowser Updater.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$BIN_DIR/PrivacyBrowserUpdater" "$HELPER/Contents/MacOS/PrivacyBrowserUpdater"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/Updater/Info.plist > "$HELPER/Contents/Info.plist"
plutil -lint "$HELPER/Contents/Info.plist" >/dev/null

# The app icon: the app draws its iconset from the Lumen mark (Sources/PrivacyBrowser/App/AppIcon.swift).
ICON_DIR="$(mktemp -d -t pbicon)"
"$BIN_DIR/PrivacyBrowser" --render-app-icon "$ICON_DIR/AppIcon.iconset" >/dev/null
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICON_DIR/AppIcon.iconset"
rm -rf "$ICON_DIR"

# The fingerprint probe the self-test and scripts/safari_reference.py share.
cp Resources/fingerprint_probe.js "$APP/Contents/Resources/fingerprint_probe.js"
# "What sites see" runs the probe and these, the scripts of CI's live comparison (scripts/live_compare.py).
cp -R Resources/SiteProbes "$APP/Contents/Resources/SiteProbes"

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

# DEBUGGABLE=1 adds get-task-allow so lldb can attach. Under the hardened runtime a signature
# without it refuses the debugger ("Not allowed to attach to process"), and hosting Safari's chrome
# is debugged by stopping inside Safari's own code. Never for a build that goes anywhere.
if [[ "${DEBUGGABLE:-0}" == "1" ]]; then
  [[ "$NE" != "1" ]] || { echo "error: DEBUGGABLE=1 does not belong in an NE build" >&2; exit 1; }
  ENTITLEMENTS_DEBUG="$(mktemp -t pbdebug).entitlements"
  cp "$ENTITLEMENTS" "$ENTITLEMENTS_DEBUG"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$ENTITLEMENTS_DEBUG"
  ENTITLEMENTS="$ENTITLEMENTS_DEBUG"
fi

TIMESTAMP="--timestamp=none"
# A Developer ID signature is notarized, and notarization needs a secure timestamp.
[[ "$NE" != "1" && "$SIGN_IDENTITY" == "-" ]] || TIMESTAMP="--timestamp"
# Inside out: the helper first (no entitlements: no sandbox), then the app, whose signature seals it.
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$HELPER"
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
if codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | grep -F "com.apple.security.app-sandbox" >/dev/null; then
  echo "error: the installer helper must not be sandboxed (it replaces the app)" >&2; exit 1
fi

# Fail loudly if the signature does not carry the expected sandbox state.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  [[ "$SANDBOX" == "1" ]] || { echo "error: unexpected sandbox entitlement" >&2; exit 1; }
  codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -F "/Library/Caches/$BUNDLE_ID.update/" >/dev/null \
    || { echo "error: the sandbox exception for the update's staging folder is missing" >&2; exit 1; }
  echo "Built $APP (bundle id $BUNDLE_ID, App Sandbox ON)"
else
  [[ "$SANDBOX" != "1" ]] || { echo "error: sandbox entitlement missing from signature" >&2; exit 1; }
  echo "Built $APP (bundle id $BUNDLE_ID, App Sandbox OFF)"
fi
echo "Run:        open $APP"
echo "Self-test:  $APP/Contents/MacOS/PrivacyBrowser --self-test"
