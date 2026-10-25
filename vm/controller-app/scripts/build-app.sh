#!/usr/bin/env bash
# Builds VMLauncher.app (SwiftUI) from this Swift package — no Xcode project needed.
#
#   vm/controller-app/scripts/build-app.sh            # release → vm/controller-app/build/VMLauncher.app
#   ZIP=1 vm/controller-app/scripts/build-app.sh      # also build/VMLauncher.zip, ready to share
#   APP_DIR=out CONFIG=debug vm/controller-app/scripts/build-app.sh
#   BUNDLE_ID=org.me.VMLauncher vm/controller-app/scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" vm/controller-app/scripts/build-app.sh
#
# The bundle carries vm/controller/tart-prototype.sh and the vm/agent files
# under Contents/Resources/vm/, the repo's own layout, so the script finds the
# agent next to it. Neither Tart nor a macOS image is bundled: the app checks
# for Tart (offering to download it) and pulls the image on first launch.
#
# Requires macOS 14+ and Xcode 15+ (or the matching Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."
VM_DIR="$(cd .. && pwd)"
BUNDLE_ID="${BUNDLE_ID:-dev.local.VMLauncher}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
CONFIG="${CONFIG:-release}"
APP_DIR="${APP_DIR:-build}"
APP="$APP_DIR/VMLauncher.app"
RESOURCES="$APP/Contents/Resources"

swift build -c "$CONFIG" --product VMLauncher
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES/vm/controller" "$RESOURCES/vm/agent"
cp "$BIN_DIR/VMLauncher" "$APP/Contents/MacOS/VMLauncher"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

install -m 0755 "$VM_DIR/controller/tart-prototype.sh" "$RESOURCES/vm/controller/"
install -m 0755 "$VM_DIR/identity.sh" "$RESOURCES/vm/"
install -m 0755 "$VM_DIR/agent/install.sh" "$RESOURCES/vm/agent/"
install -m 0644 "$VM_DIR/agent/pbagent.py" "$VM_DIR/agent/binarycookies.py" \
  "$VM_DIR/agent/com.privacybrowser.agent.plist.template" \
  "$RESOURCES/vm/agent/"

# Hardened runtime, no App Sandbox: the app has to run tart, bash and ssh.
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Fail the build if the bundle can't actually find its script and agent.
"$APP/Contents/MacOS/VMLauncher" --self-check

if [[ "${ZIP:-}" == "1" ]]; then
  # ditto keeps permissions and the signature intact (a plain zip of an .app may not).
  rm -f "$APP_DIR/VMLauncher.zip"
  ditto -c -k --keepParent "$APP" "$APP_DIR/VMLauncher.zip"
  echo "Zipped: $APP_DIR/VMLauncher.zip"
fi
echo "Built $APP (bundle id $BUNDLE_ID)"
echo "Run:   open $APP"
