#!/usr/bin/env bash
# The App Store build of Lumen for iPhone: an archive for devices, checked, then exported for App
# Store Connect. Runs on a Mac with Xcode 26+ and xcodegen.
#
#   ios/scripts/build-release.sh                     # unsigned archive, checked: what CI runs (no team yet)
#   APP_VERSION=1.0.0 APP_BUILD=7 TEAM_ID=ABCDE12345 ios/scripts/build-release.sh
#                                                    # signed (automatic signing, Apple Distribution) and
#                                                    # exported: build/release/export/Lumen.ipa
#   … ASC_KEY_PATH=AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=… ios/scripts/build-release.sh
#                                                    # the same on a Mac without the team's Apple ID in
#                                                    # Xcode: an App Store Connect API key lets
#                                                    # xcodebuild make the certificate and profile
#   UPLOAD=1 …                                       # export straight to App Store Connect (TestFlight)
#
#   APP_VERSION   CFBundleShortVersionString (default: project.yml's MARKETING_VERSION)
#   APP_BUILD     CFBundleVersion, a whole number larger than every build already sent (default 1)
#   ENTITLEMENT_PUBLIC_KEYS="<key id>=<base64>[,…]"  other keys for the documents of rights than the
#                 production one of project.yml (a change of the server's key); a key anyone knows is
#                 refused before anything is built (release_rules.py, rule 3)
#   OUT           where the archive and the export go (default ios/build/release)
#
# Before the build: the sources' release rules and the texts' table. After it, in the archive's app:
# the release rules with the binary (rule 4: no test switch, no testbed exception), the keys for the
# documents of rights (the production one and no other, unless ENTITLEMENT_PUBLIC_KEYS), the privacy
# manifest, the version and build asked for. Any breach: exit 1 and nothing exported.
# CHECK_ONLY=1 stops after the checks made before the build (CI's red for the refused key).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$HERE/build/release}"
PRODUCTION_KEYS="63a9a50f8cc6f129=bOCnaE4nVmmeqieu9CNIo0AY86OOYqe65OwSJbTwYn0="
APP_BUILD="${APP_BUILD:-1}"
APP_VERSION="${APP_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$HERE/project.yml" | head -1)}"
KEYS="${ENTITLEMENT_PUBLIC_KEYS:-}"
TEAM_ID="${TEAM_ID:-}"
say() { printf '%s\n' "$*"; }
fail() { say "REFUSED: $*"; exit 1; }

# ---- Before anything is built.
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "APP_VERSION '$APP_VERSION' is not 1, 1.2 or 1.2.3"
[[ "$APP_BUILD" =~ ^[1-9][0-9]*$ ]] || fail "APP_BUILD '$APP_BUILD' is not a whole number above 0"
if [[ -n "$KEYS" ]]; then
    [[ "$KEYS" =~ ^[0-9a-f]{16}=[A-Za-z0-9+/]{43}=(,[0-9a-f]{16}=[A-Za-z0-9+/]{43}=)*$ ]] \
        || fail "ENTITLEMENT_PUBLIC_KEYS is not <key id>=<base64 of 32 bytes>[,…]"
    known="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import release_rules as r; print(r.known_key_in(sys.argv[2]) or "")' \
        "$HERE/scripts" "$KEYS")"
    [[ -z "$known" ]] || fail "ENTITLEMENT_PUBLIC_KEYS holds $known — anyone could sign themselves a plan with it"
fi
python3 "$HERE/scripts/release_rules.py" "$HERE" || fail "the release rules are broken in the sources"
python3 "$HERE/scripts/check_strings.py" "$HERE" >/dev/null || fail "the texts' table (check_strings.py)"
say "before the build: version $APP_VERSION ($APP_BUILD), keys ${KEYS:-the production one}, rules and texts OK"
[[ "${CHECK_ONLY:-0}" == "1" ]] && exit 0

# ---- The archive.
command -v xcodegen >/dev/null || fail "no xcodegen (brew install xcodegen)"
(cd "$HERE" && xcodegen generate --quiet)
rm -rf "$OUT"; mkdir -p "$OUT"
ARCHIVE="$OUT/Lumen.xcarchive"
AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    : "${ASC_KEY_ID:?ASC_KEY_PATH needs ASC_KEY_ID}" "${ASC_ISSUER_ID:?ASC_KEY_PATH needs ASC_ISSUER_ID}"
    AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
if [[ -n "$TEAM_ID" ]]; then
    SIGNING=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution")
    PROVISIONING=(-allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"})
else
    SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
    PROVISIONING=()
fi
say "archiving ($([[ -n "$TEAM_ID" ]] && echo "signed for team $TEAM_ID" || echo unsigned))…"
if ! xcodebuild archive -project "$HERE/Lumen.xcodeproj" -scheme Lumen -configuration Release \
        -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
        ${PROVISIONING[@]+"${PROVISIONING[@]}"} "${SIGNING[@]}" \
        MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_BUILD" \
        ENTITLEMENT_PUBLIC_KEYS="$KEYS" >"$OUT/archive.txt" 2>&1; then
    grep -E "error:|error " "$OUT/archive.txt" | head -30
    fail "the archive did not build (the whole log: $OUT/archive.txt)"
fi
APP="$ARCHIVE/Products/Applications/Lumen.app"
[[ -d "$APP" ]] || fail "no Lumen.app in the archive"

# ---- What was archived.
python3 "$HERE/scripts/release_rules.py" "$HERE" --release-app "$APP" || fail "the release rules are broken in the archive's app"
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null; }
[[ "$(info CFBundleShortVersionString)" == "$APP_VERSION" ]] || fail "the app says version $(info CFBundleShortVersionString), not $APP_VERSION"
[[ "$(info CFBundleVersion)" == "$APP_BUILD" ]] || fail "the app says build $(info CFBundleVersion), not $APP_BUILD"
carried="$(python3 -c 'import plistlib, sys; keys = plistlib.load(open(sys.argv[1] + "/Info.plist", "rb")).get("PBEntitlementPublicKeys") or {}; print(",".join(f"{i}={k}" for i, k in sorted(keys.items())))' "$APP")"
wanted="$(tr ',' '\n' <<<"${KEYS:-$PRODUCTION_KEYS}" | sort | paste -sd, -)"
[[ "$carried" == "$wanted" ]] || fail "the app trusts ${carried:-no key}, not ${wanted}"
[[ -f "$APP/PrivacyInfo.xcprivacy" ]] && plutil -lint "$APP/PrivacyInfo.xcprivacy" >/dev/null \
    || fail "the app carries no readable privacy manifest"
[[ -d "$APP/Frameworks" ]] && [[ -n "$(find "$APP/Frameworks" -name '*.dylib' -o -name '*.framework' | head -1)" ]] \
    && say "note: frameworks inside: $(ls "$APP/Frameworks" | tr '\n' ' ')"
size="$(du -sk "$APP" | cut -f1)"
say "archived: Lumen $APP_VERSION ($APP_BUILD), $((size / 1024)) MB, keys ${carried%%=*}…, privacy manifest, release rules OK"

# ---- The export (a team only: an unsigned archive cannot be exported).
if [[ -z "$TEAM_ID" ]]; then
    say "no TEAM_ID: the archive is checked and not exported ($ARCHIVE)"
    exit 0
fi
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([[ "${UPLOAD:-0}" == "1" ]] && echo upload || echo export)</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" ${PROVISIONING[@]+"${PROVISIONING[@]}"} >"$OUT/export.txt" 2>&1; then
    grep -E "error:|error " "$OUT/export.txt" | head -30
    fail "the export failed (the whole log: $OUT/export.txt)"
fi
if [[ "${UPLOAD:-0}" == "1" ]]; then
    say "sent to App Store Connect: Lumen $APP_VERSION ($APP_BUILD) — it appears in TestFlight once processed"
else
    say "exported: $(ls "$OUT"/export/*.ipa) — send it with Transporter, or again with UPLOAD=1"
fi
