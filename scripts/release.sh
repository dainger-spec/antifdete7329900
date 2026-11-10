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
#   DOWNLOAD_URL=https://…/            the folder the zip and the disk image are published in (default: next
#                              to FEED_URL — a release's image is https://dl.lumenbrowser.io/Lumen-<version>.dmg)
#   R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY   (and R2_BUCKET, default lumen-downloads)
#                              publish in Cloudflare R2, the bucket behind dl.lumenbrowser.io
#                              (scripts/r2_publish.sh): before anything is built, the release's names are
#                              checked free and the appcast published now is fetched, its releases kept;
#                              at the end the zip and the disk image first, the appcast last, each read
#                              back from its public address and its SHA-256 compared with the built
#                              file's — any difference fails the release. Without them the script says
#                              what goes where. From the environment only: never written anywhere
#   PREVIOUS_APPCAST=path      the appcast published now: its releases are kept in the new one
#   NE=1 APP_PROFILE=path EXTENSION_PROFILE=path
#                              with the network guard: WebRTC in a proxied profile goes through its
#                              proxy (docs/TUNNEL.md). The two Developer ID provisioning profiles of
#                              docs/IDENTITY.md; build-app.sh embeds and signs the extension. Without
#                              NE the release has no guard, and a proxied profile keeps WebRTC off.
#   CAM=1 CAMERA_PROFILE=path  with the system virtual camera: the substituted camera is a real
#                              device at the system level, undetectable by a page's JavaScript
#                              (docs/CAMERA.md). build-app.sh embeds and signs its extension; with
#                              NE=1 the release then carries two system extensions (the guard and the
#                              camera), each signed by TEAM_ID. Without CAM the camera is the in-page
#                              shim only. Needs its own Developer ID provisioning profile.
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
# A release — signed with a Developer ID, or published — is made only from a commit the full CI
# pipeline (.github/workflows/full.yml) passed, from a tree with nothing changed beside it: step 0b
# asks GitHub (scripts/full_run_gate.py) and stops before anything is built. Start a full run of the
# commit with `git tag full/<sha12> <sha> && git push origin full/<sha12>`.
#
# Nor is one made while the server signs no automation into the documents of rights (step 0a,
# scripts/automation_plan_gate.py; the owner and the lead, 9 November): the app's automation is the
# plan's, and against a server without the field it would be refused to everyone.
#
# The private key never enters the repository, CI or the app; only its public half is built in. Nor
# do R2's keys: the release stops first if any of them, or anything shaped like R2's, is in a commit
# (scripts/check_secrets.py).
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

# 0. No secret of a release in the repository, which is public: the keys in this environment and
# anything shaped like R2's, in every commit any ref reaches, the index and what `git add -A` would
# take (scripts/check_secrets.py). A finding stops the release before anything is built.
python3 scripts/check_secrets.py

# Published when R2's keys are given (scripts/r2_publish.sh reads them from the environment, and
# R2_BUCKET defaults to lumen-downloads); a dry run never is.
PUBLISH=""
if [[ -n "${R2_ENDPOINT:-}${R2_ACCESS_KEY_ID:-}${R2_SECRET_ACCESS_KEY:-}" ]]; then
  : "${R2_ENDPOINT:?R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com)}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID}" "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY}"
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: a dry run is never uploaded" >&2; exit 1; }
  PUBLISH=1
fi

# 0a. The server signs automation into the documents of rights. The automation API and scenario runs
# are the plan's (`features` names `automation`), and the owner and the lead, 9 November: no build
# with that gate is released while the server does not sign the field — against it the API would
# refuse everyone. scripts/automation_plan_gate.py reads the app's copy of the server's vectors: a
# release stops until they show the trial, Professional and Team with automation and Personal
# without. A dry run says so in its block.
plan_status=0
plan_line="$(python3 scripts/automation_plan_gate.py)" || plan_status=$?
echo "$plan_line"
if (( plan_status != 0 )); then
  if [[ "$SIGN_IDENTITY" != "-" || -n "$PUBLISH" ]]; then
    echo "error: the server's vectors do not show automation signed by plan (the line above): nothing is built, signed or published" >&2
    exit 1
  fi
  DRY+=("the server does not sign automation into the documents of rights yet (scripts/automation_plan_gate.py, the line above): a signed or published release stops on it")
fi

# 0b. The full pipeline passed on this very commit. The owner, 3 November: the checks are split —
# the fast ones on every push (.github/workflows/ci.yml), every other one once a day and on request
# (.github/workflows/full.yml) — and a release on a commit the full pipeline has not passed is not
# allowed. A release is what is signed with a Developer ID or published: it needs a tree with no
# change beside the commit (what is built is the commit the full run checked, nothing else) and a
# run of full.yml on that commit that passed (scripts/full_run_gate.py asks GitHub). Before anything
# is built. A dry run says what it would need.
HEAD_SHA="$(git rev-parse HEAD)"
TREE_CHANGES="$(git status --porcelain)"
gate_status=0
gate_line="$(python3 scripts/full_run_gate.py --sha "$HEAD_SHA")" || gate_status=$?
echo "$gate_line"
if [[ "$SIGN_IDENTITY" != "-" || -n "$PUBLISH" ]]; then
  if [[ -n "$TREE_CHANGES" ]]; then
    echo "error: the tree has changes beside commit ${HEAD_SHA:0:12} (git status below): a release is built from a commit the full pipeline passed, nothing else" >&2
    echo "$TREE_CHANGES" | head -n 20 >&2
    exit 1
  fi
  (( gate_status == 0 )) || { echo "error: no passed full run of ${HEAD_SHA:0:12} (the line above): nothing is built, signed or published" >&2; exit 1; }
else
  (( gate_status == 0 )) || DRY+=("$gate_line — a signed or published release stops on it")
  [[ -z "$TREE_CHANGES" ]] || DRY+=("the tree has changes beside ${HEAD_SHA:0:12}: a signed or published release stops on it")
fi

rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Before the build (it and notarization take a while): the release's names are free in the bucket —
# a published version is never replaced, so a VERSION already there stops it here, and R2's keys are
# tried — and the appcast published now is fetched from the bucket, so that the new one keeps its
# releases (unless PREVIOUS_APPCAST names another).
if [[ -n "$PUBLISH" ]]; then
  scripts/r2_publish.sh --free "${DOWNLOAD_URL}Lumen-$VERSION.zip"
  scripts/r2_publish.sh --free "${DOWNLOAD_URL}Lumen-$VERSION.dmg"
  if [[ -z "${PREVIOUS_APPCAST:-}" ]]; then
    scripts/r2_publish.sh --current "$FEED_URL" "$OUT/previous-appcast.json"
    [[ ! -f "$OUT/previous-appcast.json" ]] || PREVIOUS_APPCAST="$OUT/previous-appcast.json"
  fi
fi

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
# The appcast whose releases the new one keeps must check with these keys — now, not after the
# build and notarization (step 4 reads it the same way).
if [[ -n "${PREVIOUS_APPCAST:-}" ]]; then
  IFS=',' read -ra TRUSTED <<< "$PUBLIC_KEYS"
  VERIFY_KEYS=()
  for entry in "${TRUSTED[@]}"; do [[ -z "$entry" ]] || VERIFY_KEYS+=(--public-key "$entry"); done
  "$PBUPDATE" verify --appcast "$PREVIOUS_APPCAST" "${VERIFY_KEYS[@]}" \
    || { echo "error: $PREVIOUS_APPCAST does not check with this update key or UPDATE_EXTRA_PUBLIC_KEYS: its releases cannot be kept" >&2; exit 1; }
fi

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
# it), no App Sandbox, library validation kept on for the app's own executable (Safari's frameworks
# load only in LumenProfile, below; beside the network guard's right the kernel kills an executable
# with it off at its start: docs/TUNNEL.md, "What the kernel kills"), and no debugger allowed to attach.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
SIGNED_FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | awk '/^CodeDirectory/ { print }')"
[[ "$SIGNED_ENTITLEMENTS" != *"com.apple.security.app-sandbox"* ]] \
  || { echo "error: the app's signature carries the App Sandbox: it would not host Safari's chrome" >&2; exit 1; }
[[ "$SIGNED_ENTITLEMENTS" == *"<key>com.apple.security.device.camera</key>"* ]] \
  || { echo "error: the app's entitlements could not be read back (no camera entitlement among them)" >&2; exit 1; }
[[ "$SIGNED_ENTITLEMENTS" != *"<key>com.apple.security.cs.disable-library-validation</key>"* ]] \
  || { echo "error: the app's own executable is signed with library validation off: only LumenProfile may be (docs/TUNNEL.md)" >&2; exit 1; }
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
# With the network guard (NE=1): the app holds what installing and running it needs, the extension
# is inside, signed by the same team, and the profile's executable — checked above — holds none of
# it. Without it, the release says so: a proxied profile keeps WebRTC off.
GUARD="not in this release: a proxied profile keeps WebRTC off (NE=1 and the profiles of docs/IDENTITY.md add it)"
if [[ "${NE:-0}" == "1" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: NE=1 needs a Developer ID signature (SIGN_IDENTITY)" >&2; exit 1; }
  APP_SIGNED="$OUT/app-entitlements.plist"
  codesign -d --entitlements - --xml "$APP" > "$APP_SIGNED" 2>/dev/null || true
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$APP_SIGNED" 2>/dev/null)" == "$TEAM_ID.$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" ]] \
    || { echo "error: NE=1, but the app is not signed with the application identifier of team $TEAM_ID" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "$APP_SIGNED" >/dev/null 2>&1 \
    || { echo "error: NE=1, but the app may not install a system extension" >&2; exit 1; }
  NE_PROVIDERS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension' "$APP_SIGNED" 2>/dev/null || true)"
  [[ "$NE_PROVIDERS" == *"content-filter-provider-systemextension"* ]] \
    || { echo "error: NE=1, but the app's signature does not carry the content filter (content-filter-provider-systemextension)" >&2; exit 1; }
  [[ -f "$APP/Contents/embedded.provisionprofile" ]] || { echo "error: NE=1, but the app has no embedded provisioning profile" >&2; exit 1; }
  shopt -s nullglob
  SYSTEM_EXTENSIONS=("$APP"/Contents/Library/SystemExtensions/*.systemextension)
  shopt -u nullglob
  # The app's own system extensions, by bundle id: the network guard (BUNDLE_ID.PacketTunnel) is
  # always required with NE=1; the system virtual camera (BUNDLE_ID.Camera) is allowed as a second
  # one only with CAM=1 (docs/CAMERA.md). Any other system extension is unexpected and fails the
  # release. The ids follow build-app.sh's defaults, overridable with the same env.
  APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  GUARD_EXT_ID="${EXTENSION_ID:-$APP_BUNDLE_ID.PacketTunnel}"
  CAMERA_EXT_ID="${CAMERA_EXTENSION_ID:-$APP_BUNDLE_ID.Camera}"
  GUARD_SYSEXT=""
  CAMERA_SYSEXT=""
  for ext in "${SYSTEM_EXTENSIONS[@]}"; do
    case "$(basename "$ext" .systemextension)" in
      "$GUARD_EXT_ID") GUARD_SYSEXT="$ext" ;;
      "$CAMERA_EXT_ID") CAMERA_SYSEXT="$ext" ;;
      *) echo "error: NE=1, but the app holds an unexpected system extension: $(basename "$ext")" >&2; exit 1 ;;
    esac
  done
  [[ -n "$GUARD_SYSEXT" ]] || { echo "error: NE=1, but the app holds no network guard extension ($GUARD_EXT_ID)" >&2; exit 1; }
  codesign --verify --strict "$GUARD_SYSEXT" \
    || { echo "error: the network guard's extension is not validly signed" >&2; exit 1; }
  [[ "$(codesign -dv "$GUARD_SYSEXT" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" == "$TEAM_ID" ]] \
    || { echo "error: the network guard's extension is not signed by team $TEAM_ID" >&2; exit 1; }
  if [[ "${CAM:-0}" == "1" ]]; then
    [[ -n "$CAMERA_SYSEXT" ]] || { echo "error: CAM=1, but the app holds no camera extension ($CAMERA_EXT_ID)" >&2; exit 1; }
    codesign --verify --strict "$CAMERA_SYSEXT" \
      || { echo "error: the camera's extension is not validly signed" >&2; exit 1; }
    [[ "$(codesign -dv "$CAMERA_SYSEXT" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" == "$TEAM_ID" ]] \
      || { echo "error: the camera's extension is not signed by team $TEAM_ID" >&2; exit 1; }
  else
    [[ -z "$CAMERA_SYSEXT" ]] || { echo "error: the app holds a camera extension but CAM is not 1" >&2; exit 1; }
  fi
  rm -f "$APP_SIGNED"
  GUARD="in this release ($(basename "$GUARD_SYSEXT")): WebRTC in a proxied profile through its proxy, once the person installs the guard (Settings › WebRTC through proxies)"
  [[ -z "$CAMERA_SYSEXT" ]] \
    || GUARD="$GUARD; system camera ($(basename "$CAMERA_SYSEXT")): the substituted camera is a real device at the system level"
fi
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

# No executable holds a relaxation of the hardened runtime beside the network extension's right
# (build-app.sh refused such a build already; read again from what is about to be notarized).
scripts/relaxation_check.sh "$APP" \
  || { echo "error: an executable of this build holds a relaxation beside the network extension's right: no release" >&2; exit 1; }

# 1b. The kernel lets the app, as signed, start — its executable and the profile's — before anything
# is sent to Apple. On 3 November 0.1.1 with the network guard (NE=1) was notarized, then killed by the
# kernel at its start on macOS 27.0.1: "Hardened Runtime relaxation entitlements disallowed on System
# Extensions" (docs/TUNNEL.md, "Status"). A build the kernel refuses is not notarized, let alone
# released (scripts/start_check.sh says what the kernel said).
scripts/start_check.sh "$APP/Contents/MacOS/Lumen" "the app's executable" \
  || { echo "error: the kernel does not let this build start: no release" >&2; exit 1; }
scripts/start_check.sh "$PROFILE_EXECUTABLE" "the profile's executable (LumenProfile)" \
  || { echo "error: the kernel does not let this build's profiles start: no release" >&2; exit 1; }

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
# hand, gets a process of its own whose window is Safari's own, and a second one beside it sees none
# of its keychain (--release-check: ReleaseCheck.swift).
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
check_status=0
env -u PB_PROFILE_PROCESS -u PB_SAFARI_CHROME "$CHECK_APP" --release-check > "$OUT/release-check.txt" 2>&1 || check_status=$?
grep '^RELEASE-CHECK' "$OUT/release-check.txt" || tail -n 20 "$OUT/release-check.txt"
# Its exit status and every line, never one PASS among them: the keychain between profiles is
# checked after the profile's window, and its FAIL stops the release too (release_check_gate.sh).
if ! scripts/release_check_gate.sh "$OUT/release-check.txt" "$check_status"; then
  echo "error: the app, signed as it ships, did not pass its release check on this Mac (its lines above): no release" >&2
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

# 3c. Whether the image's window shows its picture: the finished image opened in Finder, its window
# captured in this Mac's appearance and compared point by point with the picture the image carries
# (scripts/dmg_window_shot.sh; the owner, 3 November: 0.1.1's window had no picture and nothing said
# so). The layout never stops a release (2 November), and this is never silent: its verdict is in the
# block at the end. The terminal needs to be allowed to record the screen once (Privacy & Security ›
# Screen & System Audio Recording). DMG_WINDOW_CHECK=0 leaves it out, and the block says that too.
if [[ "${DMG_WINDOW_CHECK:-1}" == "0" ]]; then
  WINDOW_VERDICT="NOT CHECKED (DMG_WINDOW_CHECK=0)"
elif scripts/dmg_window_shot.sh "$OUT/$DMG_NAME" "$OUT/dmg-window" 2>&1 | tee "$OUT/dmg-window.txt"; then
  WINDOW_VERDICT="shows its picture, compared point by point ($OUT/dmg-window)"
else
  WINDOW_VERDICT="DOES NOT SHOW ITS PICTURE, or could not be captured: $OUT/dmg-window.txt says which"
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

# 5b. For the website, in one piece (the owner: the site's build needs them): the image's address,
# the version, its size in megabytes (decimal, as Finder counts), its SHA-256, the macOS it needs.
# Written by a JSON serializer — 0.1.1's, put together by awk and a template, said "sizeMB": 17,5 on a
# Mac whose locale writes a decimal comma — and read back as the site reads it, before anything is
# published: a file that is not valid JSON, or whose fields are not this image's, stops the release
# (scripts/download_json.py).
python3 scripts/download_json.py write --dmg "$OUT/$DMG_NAME" --version "$VERSION" --build "$BUILD" \
  --url "$DOWNLOAD_URL$DMG_NAME" --minimum-system "$MINIMUM_SYSTEM" --out "$OUT/download.json"
python3 scripts/download_json.py check "$OUT/download.json" --dmg "$OUT/$DMG_NAME" --minimum-system "$MINIMUM_SYSTEM" \
  || { echo "error: download.json is not what the website can read (above): nothing published" >&2; exit 1; }

# 5c. The website says the minimum macOS the app needs (its LSMinimumSystemVersion), in words: 0.1.1
# needed 14.0 by its Info.plist, download.json and appcast while the site said macOS 26 and newer
# (scripts/site_minimum_check.py reads the site's pages). A release that publishes, whose site says
# another or cannot be read, publishes nothing; a run that publishes nothing (a dry run, or no R2
# keys) says so in its block and goes on.
site_status=0
python3 scripts/site_minimum_check.py --minimum "$MINIMUM_SYSTEM" --site "$ACCOUNT_SITE_URL" || site_status=$?
if (( site_status != 0 )); then
  if [[ "$SIGN_IDENTITY" == "-" || -z "$PUBLISH" ]]; then
    DRY+=("the website's minimum macOS is not confirmed (scripts/site_minimum_check.py: exit $site_status, lines above): a release that publishes stops on it")
  else
    echo "error: the website does not say macOS $MINIMUM_SYSTEM and newer, as the app needs, or could not be read (above): nothing published" >&2
    exit 1
  fi
fi

# 6. Published: the zip and the image first, the appcast last — never a feed naming a file that is
# not there yet — each read back from its public address and its SHA-256 compared with the built
# file's; any difference fails the release (scripts/r2_publish.sh). Cache: the versioned files for a
# year, the appcast never. If this step fails, the files are still in $OUT: running r2_publish.sh on
# them again, in the same order, finishes the publication (the same bytes are only read back).
if [[ -n "$PUBLISH" ]]; then
  scripts/r2_publish.sh "$OUT/$ZIP_NAME" "$DOWNLOAD_URL$ZIP_NAME" application/zip "public, max-age=31536000, immutable"
  scripts/r2_publish.sh "$OUT/$DMG_NAME" "$DOWNLOAD_URL$DMG_NAME" application/x-apple-diskimage "public, max-age=31536000, immutable"
  scripts/r2_publish.sh "$OUT/appcast.json" "$FEED_URL" application/json "no-cache" --replace
  PUBLISHED="published and read back: what $DOWNLOAD_URL serves is, byte for byte, what was built"
else
  PUBLISHED="not uploaded (no R2_* keys): publish the zip and the image first, the appcast last"
fi

echo
echo "Release $VERSION ($BUILD) in $OUT:"
echo "  $ZIP_NAME   at $DOWNLOAD_URL$ZIP_NAME (the updater's)"
echo "  $DMG_NAME   at $DOWNLOAD_URL$DMG_NAME (the website's)"
echo "  appcast.json   at $FEED_URL"
echo "  update key     $KEY_ID"
echo "  network guard  $GUARD"
echo "  the image's window  $WINDOW_VERDICT"
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
