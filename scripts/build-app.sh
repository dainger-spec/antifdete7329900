#!/usr/bin/env bash
# Builds Lumen.app from the Swift package (no Xcode project needed). The SwiftPM product, its
# target and modules keep the code's name, PrivacyBrowser; the bundle and its executable are Lumen.
#
#   scripts/build-app.sh                       # sandboxed build (development; never released) → build/Lumen.app
#   SANDBOX=0 scripts/build-app.sh             # hardened runtime without App Sandbox: the build that is
#                                              # released (release.sh), profiles in Safari's window
#   APP_DIR=build/variant scripts/build-app.sh # output directory
#   BUNDLE_ID=org.me.PB scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# With the network guard, the content-filter system extension that holds a profile whose WebRTC
# goes through its proxy to that proxy (docs/TUNNEL.md) — needs the team's Network Extensions
# capability (content filter) and provisioning profiles for the app and the extension:
#   NE=1 TEAM_ID=ABCDE12345 SIGN_IDENTITY="Developer ID Application: … (ABCDE12345)" \
#     APP_PROFILE=path/app.provisionprofile EXTENSION_PROFILE=path/guard.provisionprofile \
#     scripts/build-app.sh
#   (EXTENSION_ID defaults to $BUNDLE_ID.PacketTunnel — the App ID registered for the extension
#   on 31 October, whose profile carries the content-filter entitlement too — and APP_GROUP to
#   $TEAM_ID.$BUNDLE_ID. NE_SIGNING=development with an "Apple Development: …" identity and
#   Development profiles, for testing on a registered Mac; the default, developer-id, is what can
#   be notarized.)
#   NE=check scripts/build-app.sh   # builds the extension and its bundle unsigned, for CI; the app
#                                   # gets the app group, the one keychain entitlement an ad hoc
#                                   # signature can carry, so CI sees profiles started without it
#
# A profile's process — and every process that runs Safari's code — is started from
# Contents/MacOS/LumenProfile, a copy of the executable signed with the base entitlements and library
# validation off: never the app's application identifier, app group or network extension rights,
# which would give every profile the app's one data-protection keychain (ProfileExecutable.swift;
# docs/IDENTITY.md). The app's own executable keeps library validation on: no executable holds a
# relaxation of the hardened runtime beside the network extension's right, which the kernel kills at
# its start (scripts/relaxation_check.sh refuses such a build; docs/TUNNEL.md).
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
BUNDLE_ID="${BUNDLE_ID:-io.lumenbrowser.Lumen}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
CONFIG="${CONFIG:-release}"
SANDBOX="${SANDBOX:-1}"
APP_DIR="${APP_DIR:-build}"
APP="$APP_DIR/Lumen.app"
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
  developer-id) NE_PROVIDER=content-filter-provider-systemextension ;;
  development) NE_PROVIDER=content-filter-provider ;;
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
# The profile's executable gets these and nothing the network guard adds below.
PROFILE_ENTITLEMENTS="$(mktemp -t pbprofile).entitlements"
cp "$ENTITLEMENTS_BUILT" "$PROFILE_ENTITLEMENTS"
# And library validation off, LumenProfile alone: Safari's frameworks are Apple's code loaded into a
# process this team signed (SafariChrome.swift), and they load only there — in a profile's process and
# in every check that runs Safari's code (SafariChromeHost.prepareForChildProcess, ProfileExecutable).
# The app's own executable keeps it on: in a build with the network guard it holds the network
# extension's right, and beside that right the kernel kills an executable with library validation off
# at its start — 0.1.1, macOS 27.0.1, 3 November (docs/TUNNEL.md, "What the kernel kills").
if [[ "$SANDBOX" != "1" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.cs.disable-library-validation" "$PROFILE_ENTITLEMENTS" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$PROFILE_ENTITLEMENTS"
fi
# The entitlements that put a process in a keychain access group (ProfileExecutable.keychainEntitlements).
KEYCHAIN_KEYS=(com.apple.application-identifier keychain-access-groups com.apple.security.application-groups com.apple.developer.team-identifier)

swift build -c "$CONFIG" --product PrivacyBrowser
swift build -c "$CONFIG" --product PrivacyBrowserUpdater
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The product is built as PrivacyBrowser and named Lumen here (CFBundleExecutable in Info.plist).
cp "$BIN_DIR/PrivacyBrowser" "$APP/Contents/MacOS/Lumen"
# The same code, for a profile's process: signed apart, without the app's keychain (above).
PROFILE_EXECUTABLE="$APP/Contents/MacOS/LumenProfile"
cp "$BIN_DIR/PrivacyBrowser" "$PROFILE_EXECUTABLE"
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
# The account server and the keys of its documents of rights (the server's docs/CONTRACT.md §2,
# §7.2): with them the build is licensed, and nothing in the environment changes them
# (AccountConfiguration). Without them — every development build — there is no licensing.
if [[ -n "${ACCOUNT_SERVER_URL:-}" ]]; then
  [[ "$ACCOUNT_SERVER_URL" == https://* ]] || { echo "error: ACCOUNT_SERVER_URL must be https" >&2; exit 1; }
  [[ -n "${ENTITLEMENT_PUBLIC_KEYS:-}" ]] || { echo "error: ACCOUNT_SERVER_URL needs ENTITLEMENT_PUBLIC_KEYS" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :PBAccountServerURL string $ACCOUNT_SERVER_URL" "$PLIST"
  [[ -z "${ACCOUNT_SITE_URL:-}" ]] || /usr/libexec/PlistBuddy -c "Add :PBAccountSiteURL string $ACCOUNT_SITE_URL" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :PBEntitlementPublicKeys dict" "$PLIST"
  IFS=',' read -ra ENTITLEMENT_KEYS <<< "$ENTITLEMENT_PUBLIC_KEYS"
  for entry in "${ENTITLEMENT_KEYS[@]}"; do
    id="${entry%%=*}"
    key="${entry#*=}"
    [[ "$id" =~ ^[0-9a-f]{16}$ && -n "$key" && "$key" != "$entry" ]] \
      || { echo "error: ENTITLEMENT_PUBLIC_KEYS: '$entry' is not <key id>=<base64>" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :PBEntitlementPublicKeys:$id string $key" "$PLIST"
  done
fi
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
HELPER="$APP/Contents/Helpers/Lumen Updater.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$BIN_DIR/PrivacyBrowserUpdater" "$HELPER/Contents/MacOS/LumenUpdater"
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

# The network guard's system extension (NE=1: signed and embedded; NE=check: built and laid out
# beside the app, unsigned, so CI checks it compiles against the SDK and its plists are valid).
if [[ "$NE" == "1" || "$NE" == "check" ]]; then
  swift build -c "$CONFIG" --product NetworkGuardExtension
  if [[ "$NE" == "1" ]]; then
    SYSEXT="$APP/Contents/Library/SystemExtensions/$EXTENSION_ID.systemextension"
  else
    SYSEXT="$APP_DIR/$EXTENSION_ID.systemextension"
    rm -rf "$SYSEXT"
  fi
  mkdir -p "$SYSEXT/Contents/MacOS"
  cp "$BIN_DIR/NetworkGuardExtension" "$SYSEXT/Contents/MacOS/NetworkGuardExtension"
  sed -e "s/\$(EXTENSION_ID)/$EXTENSION_ID/g" -e "s/\$(APP_GROUP)/$APP_GROUP/g" -e "s/\$(EXTENSION_VERSION)/$EXTENSION_VERSION/g" \
    -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/NetworkGuard/Info.plist > "$SYSEXT/Contents/Info.plist"
  plutil -lint "$SYSEXT/Contents/Info.plist" >/dev/null
  # A content filter, and nothing that carries traffic: the one provider class is the filter's.
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.filter-data' "$SYSEXT/Contents/Info.plist")" \
     == "NetworkGuardExtension.GuardFilterProvider" ]] \
    || { echo "error: the extension's Info.plist does not name its filter class" >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEProviderClasses' "$SYSEXT/Contents/Info.plist" | grep -c ' = ')" == "1" ]] \
    || { echo "error: the network guard declares a provider other than its filter" >&2; exit 1; }
  # NEProviderClasses names NetworkGuardExtension.GuardFilterProvider: the Objective-C runtime
  # knows a Swift class by its mangled name, which must be in the binary.
  # (grep reads all of it: `grep -q` stopping early would fail the pipe under pipefail.)
  strings "$SYSEXT/Contents/MacOS/NetworkGuardExtension" | grep -x '_TtC21NetworkGuardExtension19GuardFilterProvider' >/dev/null \
    || { echo "error: the extension has no NetworkGuardExtension.GuardFilterProvider class" >&2; exit 1; }
  EXT_ENTITLEMENTS="$(mktemp -t pbguard).entitlements"
  sed -e "s/\$(EXTENSION_ID)/$EXTENSION_ID/g" -e "s/\$(APP_GROUP)/$APP_GROUP/g" -e "s/\$(TEAM_ID)/$TEAM_ID/g" \
    -e "s/\$(NE_PROVIDER)/$NE_PROVIDER/g" Resources/NetworkGuard/NetworkGuard.entitlements > "$EXT_ENTITLEMENTS"
  plutil -lint "$EXT_ENTITLEMENTS" >/dev/null
  # The guard opens no connection of its own: without these it cannot carry a byte anywhere. The
  # keys themselves are read (a comment that names them is not a claim).
  for key in com.apple.security.network.client com.apple.security.network.server; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$EXT_ENTITLEMENTS" >/dev/null 2>&1; then
      echo "error: the network guard must not be entitled to open connections ($key)" >&2; exit 1
    fi
  done
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
    /usr/libexec/PlistBuddy -c "Add :PBGuardExtensionBundleIdentifier string $EXTENSION_ID" "$APP/Contents/Info.plist"
  else
    # CI: the app group alone, which an ad hoc signature can carry. Not the application identifier:
    # run 646 found an ad hoc signature carrying it not let start on CI's runners — though run 666
    # started a copy of the release's app signed ad hoc with it beside camera, microphone and library
    # validation off; which pairing the kernel refuses is not measured. The app then holds a keychain
    # entitlement its profiles must not, as an NE=1 build does, and the self-test's keychain check can
    # tell them apart.
    ENTITLEMENTS_CHECK="$(mktemp -t pbappcheck).entitlements"
    cp "$ENTITLEMENTS" "$ENTITLEMENTS_CHECK"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
      -c "Add :com.apple.security.application-groups:0 string $APP_GROUP" "$ENTITLEMENTS_CHECK"
    ENTITLEMENTS="$ENTITLEMENTS_CHECK"
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
  # Safari's code is debugged in a profile's process.
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$PROFILE_ENTITLEMENTS"
fi

TIMESTAMP="--timestamp=none"
# A Developer ID signature is notarized, and notarization needs a secure timestamp.
[[ "$NE" != "1" && "$SIGN_IDENTITY" == "-" ]] || TIMESTAMP="--timestamp"
# Inside out: the helper first (no entitlements: no sandbox), the profile's executable (the base
# entitlements, under the app's identifier: the network guard knows a profile's process by it), then
# the app, whose signature seals both.
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$HELPER"
codesign --force --options runtime "$TIMESTAMP" --identifier "$BUNDLE_ID" \
  --entitlements "$PROFILE_ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$PROFILE_EXECUTABLE"
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
codesign --verify --strict "$PROFILE_EXECUTABLE"
# No executable holds a relaxation of the hardened runtime beside the network extension's right: the
# kernel kills it at its start, after it was notarized (0.1.1, 3 November). Read from every
# executable's signature (scripts/relaxation_check.sh holds the measured list; allow-jit is not on
# it). A build that does is refused and removed: nothing the kernel would kill is left to be
# notarized or sent.
if ! scripts/relaxation_check.sh "$APP"; then
  rm -rf "$APP"
  echo "error: this build is refused (above), and $APP removed" >&2
  exit 1
fi
# The profile's executable carries no keychain of its own, whatever the app carries: read back from
# its signature, key by key (a comment or a string that names one is not the key itself).
PROFILE_SIGNED="$(mktemp -t pbprofilesigned).plist"
codesign -d --entitlements - --xml "$PROFILE_EXECUTABLE" > "$PROFILE_SIGNED" 2>/dev/null || true
# The reading's own control: the camera entitlement every executable of the app is signed with. A
# reading that does not show it shows nothing, and the check below would pass on nothing.
/usr/libexec/PlistBuddy -c "Print :com.apple.security.device.camera" "$PROFILE_SIGNED" >/dev/null 2>&1 \
  || { echo "error: the profile's executable's entitlements could not be read back" >&2; exit 1; }
for key in "${KEYCHAIN_KEYS[@]}"; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PROFILE_SIGNED" >/dev/null 2>&1; then
    echo "error: the profile's executable is signed with $key: every profile would share the app's keychain" >&2; exit 1
  fi
done
if [[ "$SANDBOX" != "1" ]]; then
  /usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.disable-library-validation" "$PROFILE_SIGNED" >/dev/null 2>&1 \
    || { echo "error: the profile's executable keeps library validation on: Safari's frameworks would not load in it" >&2; exit 1; }
fi
[[ "$(codesign -d -v "$PROFILE_EXECUTABLE" 2>&1 | awk -F= '/^Identifier=/ { print $2 }')" == "$BUNDLE_ID" ]] \
  || { echo "error: the profile's executable is not signed as $BUNDLE_ID (the network guard knows a profile by it)" >&2; exit 1; }
# Said, not checked (the app may hold them): no pipe and no failing test here, which `set -e` would
# end the build on without a word.
APP_SIGNED_XML="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
APP_KEYCHAIN=""
for key in "${KEYCHAIN_KEYS[@]}"; do
  if [[ "$APP_SIGNED_XML" == *"<key>$key</key>"* ]]; then APP_KEYCHAIN+="$key "; fi
done
echo "Keychain: the app's executable holds ${APP_KEYCHAIN:-none of the keychain entitlements}; LumenProfile holds none"
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
echo "Self-test:  $APP/Contents/MacOS/Lumen --self-test"
