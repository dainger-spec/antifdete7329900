#!/bin/bash
# The Mac state a sweep runs on (.github/workflows/sweep.yml, scripts/sweep.py), set up on a CI runner:
#
#   scripts/sweep_state.sh <state> <out folder>
#
# Prints the environment the sweep runs with (`export NAME=value` lines, for `eval`), and writes what
# it did, and what this Mac then is, to <out>/state.txt. Every state starts as a first launch of the
# app: no preferences of its own and nothing in its Application Support. The states:
#
#   default        the runner as it is: English, light, its own screen, the profile behind an HTTP proxy
#   russian        a Russian Mac: the system's language and region Russian, the Russian – PC keyboard
#                  selected, the profile in Russian with Yandex, behind a SOCKS5 proxy, dark appearance
#   first-run      the app as a new tester first opens it (scripts/first_run_sweep.swift): the welcome,
#                  the master password, the account's screens, the first profile
#   safari-used    a Mac whose person uses the real Safari: it is launched, browses two sites (history,
#                  caches, cookies, its container's data, a session to restore) and is quit before the
#                  sweep; light appearance, the profile behind SOCKS5
#   fresh-mac      a Mac whose Safari never ran (its folders, container, preferences and caches gone),
#                  a 1280×800 screen, Increase Contrast, Reduce Transparency, Reduce Motion and larger
#                  text, light appearance, and three other profiles running beside the swept one
#
# What a runner refuses (a protected container, a screen mode it does not have) is said, not failed.
set -uo pipefail
STATE="${1:?a state: default, russian, first-run, safari-used or fresh-mac}"
OUT="${2:?an output folder}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
LOG="$OUT/state.txt"
: > "$LOG"
say() { echo "$*" >> "$LOG"; }
run() { say "\$ $*"; "$@" >> "$LOG" 2>&1; say "(exit $?)"; }
appearance() {
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >> "$LOG" 2>&1
  say "dark mode $1: exit $?"
}

# A first launch of the app, whatever ran before.
run defaults delete io.lumenbrowser.Lumen
run rm -rf "$HOME/Library/Application Support/Lumen" "$HOME/Library/Application Support/io.lumenbrowser.Lumen" \
  "$HOME/Library/Caches/io.lumenbrowser.Lumen" "$HOME/Library/Saved Application State/io.lumenbrowser.Lumen.savedState"
# Back to the runner's own language, region and appearance (an earlier state of the same job set them).
run defaults delete -g AppleLanguages
run defaults delete -g AppleLocale
appearance false

case "$STATE" in
  default|first-run)
    echo "export PB_SWEEP_PROXY=http"
    ;;
  russian)
    run defaults write -g AppleLanguages -array ru-RU en-US
    run defaults write -g AppleLocale ru_RU
    appearance true
    echo "export PB_SWEEP_PROXY=socks PB_SWEEP_LANGUAGE=ru-RU PB_SWEEP_ENGINE=yandex"
    echo "export PB_SWEEP_INPUT_SOURCE=com.apple.keylayout.RussianWin PRIVACYBROWSER_LANG=ru"
    ;;
  safari-used)
    # The real Safari opened as a person opens it (Launch Services, no Apple Events), two sites
    # browsed, then quit: what it keeps in ~/Library/Safari and its container is there, as on the
    # Macs of people who use Safari besides the app.
    for site in "https://www.apple.com/" "https://en.wikipedia.org/wiki/Tea"; do
      run open -a Safari "$site"
      sleep 12
    done
    osascript -e 'quit app "Safari"' >> "$LOG" 2>&1 || pkill -x Safari
    sleep 4
    pgrep -x Safari >/dev/null && { say "Safari still running: killed"; pkill -x Safari; }
    run ls -la "$HOME/Library/Safari" "$HOME/Library/Containers/com.apple.Safari/Data/Library/Safari"
    echo "export PB_SWEEP_PROXY=socks"
    ;;
  fresh-mac)
    osascript -e 'quit app "Safari"' >/dev/null 2>&1
    for place in "$HOME/Library/Safari" "$HOME/Library/Containers/com.apple.Safari" \
                 "$HOME/Library/Containers/com.apple.Safari.WebApp" "$HOME/Library/Preferences/com.apple.Safari.plist" \
                 "$HOME/Library/Preferences/com.apple.Safari.SafeBrowsing.plist" "$HOME/Library/Caches/com.apple.Safari" \
                 "$HOME/Library/WebKit/com.apple.Safari" "$HOME/Library/Cookies/Cookies.binarycookies"; do
      if [[ -e "$place" ]]; then
        rm -rf "$place" 2>> "$LOG" || sudo -n rm -rf "$place" 2>> "$LOG"
        [[ -e "$place" ]] && say "still there (protected): $place" || say "removed: $place"
      else
        say "absent: $place"
      fi
    done
    run killall -u "$USER" cfprefsd
    for key in increaseContrast reduceTransparency reduceMotion; do
      run defaults write com.apple.universalaccess "$key" -bool true
    done
    # Larger text: the system's text size for apps that follow it, and the menu bar's.
    run defaults write -g AppleFontSize -int 15
    run defaults write com.apple.universalaccess FontSizeCategory -string "UICTContentSizeCategoryXL"
    run swift "$HERE/sweep_display.swift" 1280 800
    echo "export PB_SWEEP_PROXY=http PB_SWEEP_PROFILES=3"
    ;;
  *)
    echo "echo unknown state $STATE; exit 1"
    ;;
esac

say "-- this Mac now:"
run sw_vers
run defaults read -g AppleLanguages
run defaults read -g AppleLocale
run defaults read -g AppleInterfaceStyle
run defaults read com.apple.universalaccess
run system_profiler SPDisplaysDataType
run ls -la "$HOME/Library/Safari" "$HOME/Library/Containers/com.apple.Safari"
