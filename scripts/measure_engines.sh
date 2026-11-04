#!/bin/bash
# Measurement (claude/measure-safari-engines, never merged). CI run 718: on runner image 20261102
# (macOS 26.7.2) Safari.app 27.2 runs a WebKit of its own while this Mac's apps run WebKit
# 21624.5.1.11.3 (Safari 26.6.2's). Is that a state a Mac lives in after Safari's update for this
# macOS, or a machine not restarted since the update? What this prints:
#   - the machine: image, macOS, when it booted, when Safari's update was installed;
#   - where Safari and each WebKit copy live, their builds, how Safari's process finds its own;
#   - which WebKit an ordinary app runs, and whether pointing the app at Safari's copy changes it.
set -u
say() { echo "ENGINES $*"; }
say "image ${ImageOS:-?} ${ImageVersion:-?}"
say "macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
say "now $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "booted $(sysctl -n kern.boottime)"
say "uptime $(uptime)"
last -5 reboot 2>/dev/null | sed 's/^/ENGINES last: /' | head -5

echo "::group::Safari"
for a in /Applications/Safari.app /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app /System/Cryptexes/App/System/Applications/Safari.app; do
  if [ -e "$a" ]; then
    say "safari $a (is $(stat -f %HT "$a")) $(defaults read "$a/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null) build $(defaults read "$a/Contents/Info.plist" CFBundleVersion 2>/dev/null)"
    say "safari $a LSEnvironment $(plutil -extract LSEnvironment json -o - "$a/Contents/Info.plist" 2>/dev/null || echo none)"
    otool -L "$a/Contents/MacOS/Safari" 2>/dev/null | grep -E "WebKit|SafariShared|Safari" | head -5 | sed 's/^/ENGINES   links: /'
    otool -l "$a/Contents/MacOS/Safari" 2>/dev/null | grep -A2 LC_RPATH | grep path | head -5 | sed 's/^/ENGINES   rpath: /'
  else
    say "safari $a absent"
  fi
done
echo "::endgroup::"

echo "::group::WebKit copies on disk"
for f in /System/Library/Frameworks/WebKit.framework \
         /System/Volumes/Preboot/Cryptexes/App/System/Library/Frameworks/WebKit.framework \
         /System/Cryptexes/App/System/Library/Frameworks/WebKit.framework \
         /Library/Apple/System/Library/StagedFrameworks/Safari/WebKit.framework; do
  p="$f/Versions/A/Resources/Info.plist"; [ -f "$p" ] || p="$f/Resources/Info.plist"
  say "webkit $f: $( [ -e "$f" ] && echo present || echo absent ) $(defaults read "$p" CFBundleVersion 2>/dev/null)"
done
for root in /System/Volumes/Preboot/Cryptexes /System/Cryptexes /Library/Apple/System/Library; do
  find "$root" -maxdepth 7 \( -name "WebKit.framework" -o -name "WebCore.framework" -o -name "com.apple.WebKit.WebContent*.xpc" \) 2>/dev/null | head -20 | while read -r x; do
    p="$x/Versions/A/Resources/Info.plist"; [ -f "$p" ] || p="$x/Resources/Info.plist"; [ -f "$p" ] || p="$x/Contents/Info.plist"
    say "found $x build $(defaults read "$p" CFBundleVersion 2>/dev/null)"
  done
done
ls -la /Library/Apple/System/Library/StagedFrameworks/Safari 2>/dev/null | sed 's/^/ENGINES staged: /' | head -20
echo "::endgroup::"

echo "::group::How Safari came to be installed"
pkgutil --pkgs 2>/dev/null | grep -iE "safari|webkit|cryptex|rsr|macos" | while read -r p; do
  say "pkg $p $(pkgutil --pkg-info "$p" 2>/dev/null | grep -E '^(version|install-time|volume|location):' | tr '\n' ' ')"
done
python3 - <<'PY'
import datetime, plistlib
try:
    with open("/Library/Receipts/InstallHistory.plist", "rb") as handle:
        entries = plistlib.load(handle)
except Exception as error:
    print("ENGINES history unreadable:", error); entries = []
for entry in entries[-25:]:
    name = entry.get("displayName", "")
    print(f"ENGINES history {entry.get('date')} | {name} | {entry.get('displayVersion', '')} | {entry.get('processName', '')} | {', '.join(entry.get('packageIdentifiers', [])[:4])}")
PY
sudo -n softwareupdate --history --all 2>&1 | head -30 | sed 's/^/ENGINES softwareupdate: /'
for c in cryptexctl; do command -v $c >/dev/null && { sudo -n $c list 2>&1 | head -20 | sed 's/^/ENGINES cryptex: /'; }; done
echo "::endgroup::"

echo "::group::Safari's own process: what it loads, its environment"
open -a Safari "about:blank"; sleep 8
for pid in $(pgrep -x Safari | head -1); do
  say "Safari pid $pid: $(ps -o command= -p "$pid")"
  ps -E -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E "^DYLD_|^__XPC_DYLD|Cryptex|Staged" | head -8 | sed 's/^/ENGINES   env: /'
  vmmap "$pid" 2>/dev/null | grep -E "WebKit.framework|WebCore.framework|JavaScriptCore.framework" | awk '{print $NF}' | sort -u | head -6 | sed 's/^/ENGINES   maps: /'
done
ps -axo pid,ppid,lstart,command | grep -E "WebKit\.(WebContent|Networking|GPU)" | grep -v grep | head -8 | sed 's/^/ENGINES web process: /'
for pid in $(pgrep -f "com.apple.WebKit.WebContent" | head -3); do
  vmmap "$pid" 2>/dev/null | grep -E "/WebCore$|/WebKit$|JavaScriptCore$" | awk '{print $NF}' | sort -u | head -4 | sed "s/^/ENGINES   web $pid maps: /"
done
osascript -e 'quit app "Safari"' >/dev/null 2>&1 || true
echo "::endgroup::"

echo "::group::An ordinary app's web view"
mkdir -p build
swiftc -O scripts/engine_probe.swift -o build/engine_probe 2>&1 | tail -5
build/engine_probe plain
for dir in /Library/Apple/System/Library/StagedFrameworks/Safari /System/Volumes/Preboot/Cryptexes/App/System/Library/Frameworks /System/Cryptexes/App/System/Library/Frameworks; do
  if [ -e "$dir/WebKit.framework" ]; then
    DYLD_VERSIONED_FRAMEWORK_PATH="$dir" build/engine_probe "versioned:$dir"
  else
    say "no WebKit.framework in $dir: nothing to point the app at"
  fi
done
echo "::endgroup::"
