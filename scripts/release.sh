#!/usr/bin/env bash
# Makes a release (docs/UPDATES.md §6): build → sign → notarize → staple → zip → sign the zip
# (Ed25519) → the release's appcast item → the signed appcast, all checked at the end with the
# same code the app checks them with (pbupdate verify).
#
#   VERSION=0.2.0 BUILD=2 scripts/release.sh
#
# What needs an Apple account or a key comes from the environment; without it the step runs dry
# and says so, so CI runs the whole path on every push:
#   SIGN_IDENTITY="Developer ID Application: … (TEAMID)"  sign with it (default: ad hoc)
#   TEAM_ID=TEAMID                                       with SIGN_IDENTITY: updates must be signed by this team
#   NOTARY_PROFILE=name        notarize with `xcrun notarytool submit --keychain-profile name --wait`, then staple
#   UPDATE_KEY_FILE=path       the Ed25519 private key (`pbupdate keygen`); default: a throwaway key (dry run)
#   UPDATE_EXTRA_PUBLIC_KEYS="<id>=<base64>,…"   keys the app also trusts (a key being rotated in or out)
#   FEED_URL=https://…/appcast.json    where the app looks for updates (default: https://updates.invalid/…)
#   DOWNLOAD_URL=https://…/            where the zips are published (default: next to FEED_URL)
#   PREVIOUS_APPCAST=path      the appcast published now: its releases are kept in the new one
#   NOTES_FILE=path            the release notes, plain text
#   SANDBOX=0|1                which build is released (default 1, as build-app.sh)
#   OUT=build/release          where everything goes
#
# The private key never enters the repository, CI or the app; only its public half is built in.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?VERSION is needed (CFBundleShortVersionString, e.g. 0.2.0)}"
: "${BUILD:?BUILD is needed (CFBundleVersion: whole numbers separated by dots, e.g. 2)}"
[[ "$BUILD" =~ ^[0-9]{1,9}(\.[0-9]{1,9}){0,7}$ ]] || { echo "error: BUILD '$BUILD' is not a build number" >&2; exit 1; }
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
FEED_URL="${FEED_URL:-https://updates.invalid/privacybrowser/appcast.json}"
[[ "$FEED_URL" == https://* ]] || { echo "error: FEED_URL must be https" >&2; exit 1; }
DOWNLOAD_URL="${DOWNLOAD_URL:-${FEED_URL%/*}/}"
[[ "$DOWNLOAD_URL" == https://* ]] || { echo "error: DOWNLOAD_URL must be https" >&2; exit 1; }
[[ "$DOWNLOAD_URL" == */ ]] || DOWNLOAD_URL="$DOWNLOAD_URL/"
OUT="${OUT:-build/release}"
[[ "$OUT" != "/" && "$OUT" != "." && "$OUT" != "$HOME" ]] || { echo "error: OUT must be a folder of its own" >&2; exit 1; }
SANDBOX="${SANDBOX:-1}"
DRY=()

rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The tool that signs and checks the feed, from this package.
swift build -c release --product pbupdate
PBUPDATE="$(swift build -c release --show-bin-path)/pbupdate"

# The update key: the release's own, or a throwaway one for a dry run.
if [[ -n "${UPDATE_KEY_FILE:-}" ]]; then
  KEY="$UPDATE_KEY_FILE"
else
  KEY="$OUT/throwaway-update.key"
  "$PBUPDATE" keygen "$KEY" >/dev/null
  DRY+=("the update key is a throwaway one (no UPDATE_KEY_FILE): this appcast proves the path, not a release")
fi
read -r KEY_ID KEY_PUBLIC < <("$PBUPDATE" public-key "$KEY")
PUBLIC_KEYS="$KEY_ID=$KEY_PUBLIC"
[[ -z "${UPDATE_EXTRA_PUBLIC_KEYS:-}" ]] || PUBLIC_KEYS="$PUBLIC_KEYS,$UPDATE_EXTRA_PUBLIC_KEYS"

# 1. Build and sign (the installer helper first, then the app: build-app.sh).
TEAM_FOR_UPDATES=""
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  DRY+=("signed ad hoc (no SIGN_IDENTITY): no Developer ID, no Team ID requirement in updates")
else
  : "${TEAM_ID:?SIGN_IDENTITY needs TEAM_ID (updates must then be signed by this team)}"
  TEAM_FOR_UPDATES="$TEAM_ID"
fi
APP_VERSION="$VERSION" APP_BUILD="$BUILD" SANDBOX="$SANDBOX" APP_DIR="$OUT/app" SIGN_IDENTITY="$SIGN_IDENTITY" \
  UPDATE_FEED_URL="$FEED_URL" UPDATE_PUBLIC_KEYS="$PUBLIC_KEYS" UPDATE_TEAM_ID="$TEAM_FOR_UPDATES" \
  scripts/build-app.sh
APP="$OUT/app/PrivacyBrowser.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] \
  || { echo "error: the app's CFBundleVersion is not $BUILD" >&2; exit 1; }
# An executable that declares macOS 15's SDK or newer gets WebKit's network loader, and with it, on
# macOS 27, this Mac fetched a certificate's missing intermediate outside a profile's proxy: every
# SDK from 15.0 on, 26.5 (what Xcode 26 declares) among them; 14.x was clean (CI run 451,
# scripts/aia_variants.py; docs/ISOLATION_AND_LIMITATIONS.md §2). Until that is closed, a release is
# made only from a build that declares an older SDK — Xcode 27's SwiftPM writes 14.0. A dry run
# says so and goes on.
DECLARED_SDK="$(xcrun vtool -show-build "$APP/Contents/MacOS/PrivacyBrowser" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "${DECLARED_SDK%%.*}" -ge 15 ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    DRY+=("the build declares SDK $DECLARED_SDK: a signed release of it would be refused (docs/ISOLATION_AND_LIMITATIONS.md §2)")
  else
    echo "error: the build declares SDK $DECLARED_SDK, which turns on WebKit's network loader: on macOS 27 a" \
      "certificate's intermediate was fetched outside a profile's proxy (docs/ISOLATION_AND_LIMITATIONS.md §2)." \
      "Build with Xcode 27, whose SwiftPM declares 14.0." >&2
    exit 1
  fi
fi

# 2. Notarize and staple (an Apple account's notary profile and a Developer ID signature).
if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
else
  DRY+=("not notarized and not stapled (needs NOTARY_PROFILE and a Developer ID): Gatekeeper would refuse this app on another Mac")
fi
codesign --verify --strict --deep "$APP"

# 3. The zip the app downloads, and its release, signed.
ZIP_NAME="PrivacyBrowser-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP_NAME"
NOTES="$OUT/notes.txt"
if [[ -n "${NOTES_FILE:-}" ]]; then cp "$NOTES_FILE" "$NOTES"; else : > "$NOTES"; fi
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
"$PBUPDATE" item --key "$KEY" --archive "$OUT/$ZIP_NAME" --version "$VERSION" --build "$BUILD" \
  --minimum-system "$MINIMUM_SYSTEM" --url "$DOWNLOAD_URL$ZIP_NAME" --notes-file "$NOTES" > "$OUT/item.json"

# 4. The appcast: this release, and those of the appcast published now.
PREVIOUS=()
if [[ -n "${PREVIOUS_APPCAST:-}" ]]; then
  PREVIOUS=(--previous "$PREVIOUS_APPCAST")
  IFS=',' read -ra EXTRA <<< "${UPDATE_EXTRA_PUBLIC_KEYS:-}"
  for entry in ${EXTRA[@]+"${EXTRA[@]}"}; do [[ -z "$entry" ]] || PREVIOUS+=(--public-key "$entry"); done
fi
# (${a[@]+"${a[@]}"}: an empty array under `set -u` in the bash 3.2 of macOS.)
"$PBUPDATE" appcast --key "$KEY" --out "$OUT/appcast.json" ${PREVIOUS[@]+"${PREVIOUS[@]}"} "$OUT/item.json"

# 5. Checked as the app will check them: the appcast's signature, and the zip against its release.
"$PBUPDATE" verify --appcast "$OUT/appcast.json" --public-key "$KEY_ID=$KEY_PUBLIC" --archive "$OUT/$ZIP_NAME" --build "$BUILD"
[[ -n "${UPDATE_KEY_FILE:-}" ]] || rm -f "$KEY"

echo
echo "Release $VERSION ($BUILD) in $OUT:"
echo "  $ZIP_NAME   publish at $DOWNLOAD_URL$ZIP_NAME"
echo "  appcast.json   publish at $FEED_URL"
echo "  update key     $KEY_ID"
if (( ${#DRY[@]} )); then
  echo "DRY RUN — what a real release still needs:"
  for line in "${DRY[@]}"; do echo "  - $line"; done
fi
