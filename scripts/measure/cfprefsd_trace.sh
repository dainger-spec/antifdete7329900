#!/bin/bash
# Measurement only, never merged: what fs_usage shows of cfprefsd writing a preferences file, so that
# the file trace can be taught to name the paths it writes through a directory descriptor.
#   cfprefsd_trace.sh OUT_DIR
# Three canary writes through cfprefsd while fs_usage traces it: a domain by name (in the account's
# ~/Library/Preferences), a domain by a path in a home of its own (as a profile's SafariDefaults), and
# a domain by a path inside a container (as Safari's code names the real Safari's). The descriptors
# cfprefsd holds open are listed before and after (lsof), and every line of the trace that names
# a canary is printed.
set -u
out="$1"
mkdir -p "$out"
stamp="$(date +%s)"
home_canary="$HOME/pbcanary-$stamp"
container="$HOME/Library/Containers/com.example.pbcanary$stamp/Data/Library/Preferences"
mkdir -p "$home_canary/Library/PrivacyBrowser" "$container"
pids="$(pgrep -x cfprefsd | tr '\n' ' ')"
echo "CFPREFSD-TRACE cfprefsd processes: $pids"
for pid in $pids; do sudo -n lsof -p "$pid" -a -d '0-999' -Fftn > "$out/lsof-before-$pid.txt" 2>&1; done
sudo -n fs_usage -w -f filesys cfprefsd > "$out/fs-cfprefsd.txt" 2>&1 &
sleep 3
defaults write "com.example.pbcanary$stamp" Canary -string "by-name-$stamp"
defaults write "$home_canary/Library/PrivacyBrowser/SafariDefaults" Canary -string "by-path-$stamp"
defaults write "$container/com.example.pbcanary$stamp" Canary -string "in-container-$stamp"
sleep 6
for pid in $pids; do sudo -n lsof -p "$pid" -a -d '0-999' -Fftn > "$out/lsof-after-$pid.txt" 2>&1; done
sudo -n pkill -INT -x fs_usage
sleep 2
echo "CFPREFSD-TRACE $(wc -l < "$out/fs-cfprefsd.txt") lines; the ones that name a canary:"
grep -n -E "pbcanary|SafariDefaults" "$out/fs-cfprefsd.txt" | cut -c1-260 | head -80
echo "CFPREFSD-TRACE lines with a directory descriptor ([N]/...), first 60:"
grep -n -E '\[[0-9]+\]/' "$out/fs-cfprefsd.txt" | cut -c1-260 | head -60
echo "CFPREFSD-TRACE the canaries' files now:"
ls -la "$HOME/Library/Preferences/com.example.pbcanary$stamp.plist" "$home_canary/Library/PrivacyBrowser/" "$container/" 2>&1 | head -20
for pid in $pids; do
  echo "CFPREFSD-TRACE lsof $pid, the directories it holds open (before):"
  awk '/^f/{fd=substr($0,2)} /^t/{type=substr($0,2)} /^n/{if (type=="DIR") print "  fd " fd " " substr($0,2)}' "$out/lsof-before-$pid.txt" | head -30
done
defaults delete "com.example.pbcanary$stamp" 2>/dev/null
rm -rf "$home_canary" "$HOME/Library/Containers/com.example.pbcanary$stamp"
exit 0
