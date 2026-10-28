#!/usr/bin/env bash
# SAFARI_GRAPH spike — how Safari is put together on this Mac: SIP, versions, where its frameworks
# live, how its executable brings the UI up (what it links and imports), and the entitlements a
# third-party process does not have. Read-only. Used by CI and by manual_check.sh.
#
#   scripts/safari_graph/facts.sh
set -uo pipefail

section() { echo; echo "== $*"; }

section "system"
sw_vers
section "SIP (GitHub's macOS runners have it off; a stock Mac has it on)"
csrutil status 2>&1

section "Safari.app"
ls -la /Applications/Safari.app 2>&1
SAFARI_APP="$(cd /Applications/Safari.app 2>/dev/null && pwd -P)"
echo "resolved: ${SAFARI_APP:-<none>}"
if [ -n "${SAFARI_APP:-}" ]; then
    plist="$SAFARI_APP/Contents/Info.plist"
    for key in CFBundleShortVersionString CFBundleVersion CFBundleIdentifier NSPrincipalClass NSMainNibFile LSMinimumSystemVersion; do
        printf '%s = %s\n' "$key" "$(defaults read "$plist" "$key" 2>/dev/null || echo '<unset>')"
    done

    section "Safari's executable (how it brings its UI up)"
    ls -la "$SAFARI_APP/Contents/MacOS/" 2>&1
    echo "-- links:"
    otool -L "$SAFARI_APP/Contents/MacOS/Safari" 2>&1 | head -40
    echo "-- the symbols it imports (its main() hands over to the framework):"
    nm -u "$SAFARI_APP/Contents/MacOS/Safari" 2>&1 | head -40
    echo "-- how it makes dyld take the staged (cryptex) frameworks: its LC_DYLD_ENVIRONMENT, if any:"
    otool -l "$SAFARI_APP/Contents/MacOS/Safari" 2>&1 | grep -A4 'LC_DYLD_ENVIRONMENT' || echo "(none)"
    echo "-- the same for SafariForWebKitDevelopment:"
    otool -l "$SAFARI_APP/Contents/MacOS/SafariForWebKitDevelopment" 2>&1 | grep -A4 'LC_DYLD_ENVIRONMENT' || echo "(none)"
    otool -L "$SAFARI_APP/Contents/MacOS/SafariForWebKitDevelopment" 2>&1 | head -10

    section "Safari's entitlements (keys only; a third-party signature cannot carry the restricted ones)"
    codesign -d --entitlements - --xml "$SAFARI_APP" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g'

    section "Safari's signature"
    codesign -dvvv "$SAFARI_APP" 2>&1 | grep -v '^Hash\|^CandidateCDHash\|^CDHash'
fi

for root in /System/Library/StagedFrameworks/Safari /System/Cryptexes/App/System/Library/StagedFrameworks/Safari; do
    section "$root"
    ls -la "$root" 2>&1 | head -40
done

section "version skew: the base system's copy against Safari's staged copy (CFBundleVersion)"
STAGED=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari
for pair in "Frameworks/WebKit" "Frameworks/JavaScriptCore" "PrivateFrameworks/WebCore" "PrivateFrameworks/SafariShared" \
            "PrivateFrameworks/SafariFoundation" "PrivateFrameworks/SafariCore" "PrivateFrameworks/Safari"; do
    name="${pair#*/}"
    base_plist="/System/Library/$pair.framework/Resources/Info.plist"
    staged_plist="$STAGED/$name.framework/Resources/Info.plist"
    base_v="$(defaults read "$base_plist" CFBundleVersion 2>/dev/null || echo '<none>')"
    staged_v="$(defaults read "$staged_plist" CFBundleVersion 2>/dev/null || echo '<none>')"
    printf '%-20s base %-22s staged %s\n' "$name" "$base_v" "$staged_v"
done

for fw in /System/Library/StagedFrameworks/Safari/Safari.framework /System/Cryptexes/App/System/Library/StagedFrameworks/Safari/Safari.framework; do
    [ -e "$fw" ] || continue
    section "$fw"
    ls -la "$fw" "$fw/Versions" 2>&1 | head -20
    bin="$fw/Versions/A/Safari"; [ -e "$bin" ] || bin="$fw/Safari"
    echo "-- binary: $bin ($( [ -e "$bin" ] && echo on disk || echo 'not on disk' ))"
    echo "-- signature:"; codesign -dvvv "$bin" 2>&1 | grep -v '^Hash\|^CandidateCDHash\|^CDHash'
    echo "-- links:"; otool -L "$bin" 2>&1 | head -60
    echo "-- exported entry points (main-like):"; nm -gU "$bin" 2>/dev/null | grep -i 'main\|launch' | head -20
done
exit 0
