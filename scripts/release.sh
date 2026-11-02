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
#   FEED_URL=https://…/appcast.json    where the app looks for updates (default: a release's
#                              https://dl.lumenbrowser.io/appcast.json; a dry run's https://updates.invalid/…)
#   DOWNLOAD_URL=https://…/            where the zip and the disk image are published (default: next to FEED_URL)
#   R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
#                              upload to Cloudflare R2 (the bucket behind dl.lumenbrowser.io): the zip and
#                              the disk image first, the appcast last, each read back over https; without
#                              them the script says what goes where
#   PREVIOUS_APPCAST=path      the appcast published now: its releases are kept in the new one
#   NOTES_FILE=path            the release notes, plain text
#   OUT=build/release          where everything goes
#
# What it makes: the zip the app's updater downloads (unchanged), the disk image the website
# offers — Lumen and a link to Applications, signed, notarized and stapled like the app inside
# (scripts/make_dmg.sh; the owner, 1 and 2 November) — the appcast, and at the end one block for
# the website: the image's address, the version, its size in megabytes, its SHA-256 (download.json).
#
# What is released is always the build without the App Sandbox: only there does a profile get a
# process of its own and Safari's own window, which is what Lumen is. SANDBOX=1 is refused, and so
# is an app that, signed as it ships, does not host Safari's chrome on this Mac (step 2b;
# docs/UPDATES.md §6, "Which build is released").
#
# The private key never enters the repository, CI or the app; only its public half is built in.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?VERSION is needed (CFBundleShortVersionString, e.g. 0.2.0)}"
: "${BUILD:?BUILD is needed (CFBundleVersion: whole numbers separated by dots, e.g. 2)}"
[[ "$BUILD" =~ ^[0-9]{1,9}(\.[0-9]{1,9}){0,7}$ ]] || { echo "error: BUILD '$BUILD' is not a build number" >&2; exit 1; }
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# A release's files are at dl.lumenbrowser.io (Cloudflare R2, the owner, 1 November); a dry run's
# app never looks anywhere real.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  FEED_URL="${FEED_URL:-https://updates.invalid/lumen/appcast.json}"
else
  FEED_URL="${FEED_URL:-https://dl.lumenbrowser.io/appcast.json}"
fi
[[ "$FEED_URL" == https://* ]] || { echo "error: FEED_URL must be https" >&2; exit 1; }
DOWNLOAD_URL="${DOWNLOAD_URL:-${FEED_URL%/*}/}"
[[ "$DOWNLOAD_URL" == https://* ]] || { echo "error: DOWNLOAD_URL must be https" >&2; exit 1; }
[[ "$DOWNLOAD_URL" == */ ]] || DOWNLOAD_URL="$DOWNLOAD_URL/"
OUT="${OUT:-build/release}"
[[ "$OUT" != "/" && "$OUT" != "." && "$OUT" != "$HOME" ]] || { echo "error: OUT must be a folder of its own" >&2; exit 1; }
if [[ "${SANDBOX:-0}" != "0" ]]; then
  echo "error: SANDBOX=$SANDBOX: a release is never the sandboxed build. In the App Sandbox Safari's frameworks" \
    "cannot be loaded and every profile runs in the app's one process, on plain WebKit — not what Lumen is" \
    "(docs/UPDATES.md §6). build-app.sh still makes that build for development." >&2
  exit 1
fi
SANDBOX=0
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

# The account server and the keys of its documents of rights (the server's docs/CONTRACT.md §2,
# §7.2): the release's, printed by `lumen-api pubkey` on the owner's server; a throwaway key for a
# dry run. Never the development server's key (445c6300da0205b1): --release-check refuses it.
ACCOUNT_SERVER_URL="${ACCOUNT_SERVER_URL:-https://api.lumenbrowser.io}"
ACCOUNT_SITE_URL="${ACCOUNT_SITE_URL:-https://lumenbrowser.io}"
if [[ -z "${ENTITLEMENT_PUBLIC_KEYS:-}" ]]; then
  [[ "$SIGN_IDENTITY" == "-" ]] || { echo "error: a release needs ENTITLEMENT_PUBLIC_KEYS (lumen-api pubkey)" >&2; exit 1; }
  "$PBUPDATE" keygen "$OUT/throwaway-entitlement.key" >/dev/null
  read -r ENT_ID ENT_PUBLIC < <("$PBUPDATE" public-key "$OUT/throwaway-entitlement.key")
  ENTITLEMENT_PUBLIC_KEYS="$ENT_ID=$ENT_PUBLIC"
  DRY+=("the documents of rights are trusted under a throwaway key (no ENTITLEMENT_PUBLIC_KEYS): no server signs with it")
fi

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
  ACCOUNT_SERVER_URL="$ACCOUNT_SERVER_URL" ACCOUNT_SITE_URL="$ACCOUNT_SITE_URL" ENTITLEMENT_PUBLIC_KEYS="$ENTITLEMENT_PUBLIC_KEYS" \
  scripts/build-app.sh
APP="$OUT/app/Lumen.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] \
  || { echo "error: the app's CFBundleVersion is not $BUILD" >&2; exit 1; }
# The signature a release needs, read back from the app: the hardened runtime (notarization requires
# it), no App Sandbox, library validation off (Safari's frameworks are loaded into a process this
# team signed: SafariChrome.swift), and no debugger allowed to attach.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
SIGNED_FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | awk '/^CodeDirectory/ { print }')"
[[ "$SIGNED_ENTITLEMENTS" != *"com.apple.security.app-sandbox"* ]] \
  || { echo "error: the app's signature carries the App Sandbox: it would not host Safari's chrome" >&2; exit 1; }
[[ "$SIGNED_ENTITLEMENTS" == *"com.apple.security.cs.disable-library-validation"* ]] \
  || { echo "error: the app's signature keeps library validation on: Safari's frameworks would not load" >&2; exit 1; }
[[ "$SIGNED_ENTITLEMENTS" != *"com.apple.security.get-task-allow"* ]] \
  || { echo "error: the app's signature lets a debugger attach (DEBUGGABLE): never in a release" >&2; exit 1; }
[[ "$SIGNED_FLAGS" == *"runtime"* ]] \
  || { echo "error: the app is not signed with the hardened runtime ($SIGNED_FLAGS)" >&2; exit 1; }
# A profile's process runs from LumenProfile (ProfileExecutable.swift): the same rules for its
# signature, and none of the entitlements that would give every profile the app's keychain.
PROFILE_EXECUTABLE="$APP/Contents/MacOS/LumenProfile"
[[ -x "$PROFILE_EXECUTABLE" ]] || { echo "error: the app has no profile executable (Contents/MacOS/LumenProfile)" >&2; exit 1; }
PROFILE_SIGNED="$OUT/profile-entitlements.plist"
codesign -d --entitlements - --xml "$PROFILE_EXECUTABLE" > "$PROFILE_SIGNED" 2>/dev/null || true
for key in com.apple.application-identifier keychain-access-groups com.apple.security.application-groups com.apple.developer.team-identifier \
           com.apple.security.app-sandbox com.apple.security.get-task-allow; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PROFILE_SIGNED" >/dev/null 2>&1; then
    echo "error: the profile's executable is signed with $key" >&2; exit 1
  fi
done
/usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.disable-library-validation" "$PROFILE_SIGNED" >/dev/null 2>&1 \
  || { echo "error: the profile's executable keeps library validation on: Safari's frameworks would not load" >&2; exit 1; }
[[ "$(codesign -d --verbose=2 "$PROFILE_EXECUTABLE" 2>&1 | awk '/^CodeDirectory/ { print }')" == *"runtime"* ]] \
  || { echo "error: the profile's executable is not signed with the hardened runtime" >&2; exit 1; }
rm -f "$PROFILE_SIGNED"
# An executable that declares macOS 15's SDK or newer gets WebKit's network loader, and with it, on
# macOS 27, this Mac fetched a certificate's missing intermediate outside a profile's proxy: every
# SDK from 15.0 on, 26.5 (what Xcode 26 declares) among them; 14.x was clean (CI run 451,
# scripts/aia_variants.py; docs/ISOLATION_AND_LIMITATIONS.md §2). Until that is closed, a release is
# made only from a build that declares an older SDK — Xcode 27's SwiftPM writes 14.0. A dry run
# says so and goes on.
DECLARED_SDK="$(xcrun vtool -show-build "$APP/Contents/MacOS/Lumen" | awk '$1 == "sdk" { print $2; exit }')"
PROFILE_SDK="$(xcrun vtool -show-build "$PROFILE_EXECUTABLE" | awk '$1 == "sdk" { print $2; exit }')"
[[ "$PROFILE_SDK" == "$DECLARED_SDK" ]] \
  || { echo "error: the profile's executable declares SDK $PROFILE_SDK, the app's $DECLARED_SDK: they are one build" >&2; exit 1; }
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

# 2b. The app as it ships hosts Safari's chrome on this Mac, or there is no release: every class and
# method the chrome and a profile's hold on its proxy rely on is in this Safari
# (--check-safari-chrome), and a profile started the way the app starts one, with nothing set by
# hand, gets a process of its own whose window is Safari's own (--release-check: ReleaseCheck.swift).
# Run from a copy, so that what is published is exactly what was signed, notarized and stapled.
CHECK_DIR="$OUT/release-check"
rm -rf "$CHECK_DIR"
mkdir -p "$CHECK_DIR"
ditto "$APP" "$CHECK_DIR/Lumen.app"
CHECK_APP="$CHECK_DIR/Lumen.app/Contents/MacOS/Lumen"
# Safari's classes are looked for where Safari's code runs: a process of the profile's executable.
if ! env -u PB_PROFILE_PROCESS -u PB_SAFARI_CHROME "$CHECK_DIR/Lumen.app/Contents/MacOS/LumenProfile" --check-safari-chrome > "$OUT/check-safari-chrome.txt" 2>&1; then
  grep -E '^(MISSING|SAFARI-CHROME)' "$OUT/check-safari-chrome.txt" >&2 || tail -n 20 "$OUT/check-safari-chrome.txt" >&2
  echo "error: this Safari lacks classes or methods Safari's chrome, or a profile's hold on its proxy, relies on: no release" >&2
  exit 1
fi
env -u PB_PROFILE_PROCESS -u PB_SAFARI_CHROME "$CHECK_APP" --release-check > "$OUT/release-check.txt" 2>&1 || true
grep '^RELEASE-CHECK' "$OUT/release-check.txt" || tail -n 20 "$OUT/release-check.txt"
if ! grep '^RELEASE-CHECK PASS' "$OUT/release-check.txt" >/dev/null; then
  echo "error: a profile of this app, signed as it ships, did not open in Safari's own window on this Mac: no release" >&2
  exit 1
fi
rm -rf "$CHECK_DIR"

# 3. The zip the app downloads, and its release, signed.
ZIP_NAME="Lumen-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP_NAME"
NOTES="$OUT/notes.txt"
if [[ -n "${NOTES_FILE:-}" ]]; then cp "$NOTES_FILE" "$NOTES"; else : > "$NOTES"; fi
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
"$PBUPDATE" item --key "$KEY" --archive "$OUT/$ZIP_NAME" --version "$VERSION" --build "$BUILD" \
  --minimum-system "$MINIMUM_SYSTEM" --url "$DOWNLOAD_URL$ZIP_NAME" --notes-file "$NOTES" > "$OUT/item.json"

# 3b. The disk image the website offers: the app as it ships — signed, notarized, stapled — and a
# link to Applications (scripts/make_dmg.sh). Then the image itself is signed, notarized and
# stapled, so that a downloaded image opens without a word from Gatekeeper even before the app
# inside is looked at.
DMG_NAME="Lumen-$VERSION.dmg"
scripts/make_dmg.sh "$APP" "$OUT/$DMG_NAME"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$OUT/$DMG_NAME"
else
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/$DMG_NAME"
fi
codesign --verify --verbose=2 "$OUT/$DMG_NAME"
if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$OUT/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/$DMG_NAME"
  xcrun stapler validate "$OUT/$DMG_NAME"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/$DMG_NAME"
else
  DRY+=("the disk image is not notarized and not stapled (needs NOTARY_PROFILE and a Developer ID): Gatekeeper would refuse it on another Mac")
fi

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

# 6. Published: the zip and the image first, the appcast last — never a feed naming a file that is
# not there yet — each read back over https and compared byte for byte (R2, when its keys are
# given). Cache: the versioned files for a year, the appcast never.
if [[ -n "${R2_ENDPOINT:-}${R2_BUCKET:-}${R2_ACCESS_KEY_ID:-}${R2_SECRET_ACCESS_KEY:-}" ]]; then
  : "${R2_ENDPOINT:?R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com)}" "${R2_BUCKET:?R2_BUCKET}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID}" "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY}"
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: a dry run is never uploaded" >&2; exit 1; }
  upload() { # file, its name in the bucket, content type, cache control
    curl --fail --silent --show-error --aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
      -H "Content-Type: $3" -H "Cache-Control: $4" --upload-file "$1" "${R2_ENDPOINT%/}/$R2_BUCKET/$2"
  }
  published() { # file, its address: what is served there is this file
    [[ "$(curl --fail --silent --show-error -H 'Cache-Control: no-cache' "$2" | shasum -a 256 | cut -d' ' -f1)" \
       == "$(shasum -a 256 "$1" | cut -d' ' -f1)" ]] || { echo "error: $2 does not serve $(basename "$1")" >&2; exit 1; }
  }
  upload "$OUT/$ZIP_NAME" "${DOWNLOAD_URL#https://*/}$ZIP_NAME" application/zip "public, max-age=31536000, immutable"
  upload "$OUT/$DMG_NAME" "${DOWNLOAD_URL#https://*/}$DMG_NAME" application/x-apple-diskimage "public, max-age=31536000, immutable"
  published "$OUT/$ZIP_NAME" "$DOWNLOAD_URL$ZIP_NAME"
  published "$OUT/$DMG_NAME" "$DOWNLOAD_URL$DMG_NAME"
  upload "$OUT/appcast.json" "${FEED_URL#https://*/}" application/json "no-cache"
  published "$OUT/appcast.json" "$FEED_URL"
  PUBLISHED="uploaded and read back"
else
  PUBLISHED="not uploaded (no R2_* keys): publish the zip and the image first, the appcast last"
fi

# 7. For the website, in one piece (the owner: the site's build needs them): the image's address,
# the version, its size in megabytes (decimal, as Finder counts), its SHA-256.
DMG_BYTES="$(stat -f%z "$OUT/$DMG_NAME")"
DMG_MB="$(awk -v b="$DMG_BYTES" 'BEGIN { printf "%.1f", b / 1000000 }')"
DMG_SHA256="$(shasum -a 256 "$OUT/$DMG_NAME" | cut -d' ' -f1)"
cat > "$OUT/download.json" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "url": "$DOWNLOAD_URL$DMG_NAME",
  "sizeMB": $DMG_MB,
  "sizeBytes": $DMG_BYTES,
  "sha256": "$DMG_SHA256",
  "minimumSystem": "$MINIMUM_SYSTEM"
}
JSON

echo
echo "Release $VERSION ($BUILD) in $OUT:"
echo "  $ZIP_NAME   at $DOWNLOAD_URL$ZIP_NAME (the updater's)"
echo "  $DMG_NAME   at $DOWNLOAD_URL$DMG_NAME (the website's)"
echo "  appcast.json   at $FEED_URL"
echo "  update key     $KEY_ID"
echo "  $PUBLISHED"
echo
echo "----- for the website: from here -----"
cat "$OUT/download.json"
echo "----- to here ($OUT/download.json) -----"
if (( ${#DRY[@]} )); then
  echo
  echo "DRY RUN — what a real release still needs:"
  for line in "${DRY[@]}"; do echo "  - $line"; done
fi
