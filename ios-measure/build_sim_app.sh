#!/usr/bin/env bash
# Builds the measurement driver for the iOS Simulator, without an Xcode project:
#
#     ios-measure/build_sim_app.sh <out-dir> [min-ios] [variant]
#
# variant "bound" adds WKAppBoundDomains (web.telegram.org, lumentest) to Info.plist and gets its
# own bundle identifier: App-Bound Domains change what WebKit allows (service workers, injection).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?out dir}"
MIN_IOS="${2:-16.0}"
VARIANT="${3:-plain}"
ARCH="$(uname -m)"   # arm64 on Apple silicon runners, x86_64 on Intel ones
APP="$OUT/LumenMeasure.app"
rm -rf "$APP"; mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
echo "SDK $(xcrun --sdk iphonesimulator --show-sdk-version) at $SDK, target $ARCH-apple-ios$MIN_IOS-simulator, variant $VARIANT"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O \
    -target "$ARCH-apple-ios$MIN_IOS-simulator" -sdk "$SDK" \
    -module-name LumenMeasure \
    -o "$APP/LumenMeasure" "$HERE/app/Driver.swift" "$HERE/app/main.swift"
cp "$HERE/app/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MIN_IOS" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTPlatformName string iphonesimulator" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" "$APP/Info.plist"
if [[ "$VARIANT" == "bound" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.lumenbrowser.measure.bound" \
        -c "Add :WKAppBoundDomains array" -c "Add :WKAppBoundDomains:0 string web.telegram.org" \
        -c "Add :WKAppBoundDomains:1 string lumentest" "$APP/Info.plist"
fi
codesign --force --sign - --timestamp=none "$APP"
echo "built $APP"
