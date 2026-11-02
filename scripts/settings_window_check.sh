#!/bin/bash
# The Settings window as the person gets it (SettingsWindowCheck.swift): the app started whole, in a
# temporary vault; Settings opened as ⌘, opens it, by the app menu's item; the window server's
# picture of the window SwiftUI's Settings scene made, read row by row for a band of a tone that is
# not the design's. In this Mac's light and dark appearance; then the control — the same window with
# the fix taken back (SettingsTitleBar) — which must fail, for a band.
#
#   scripts/settings_window_check.sh path/to/Lumen.app [folder]
#
# The UI snapshots draw SettingsView in a window of their own with cacheDisplay: not the Settings
# scene's window, and none of what the window server adds over the content. A grey band of the title
# bar was invisible to them (the owner, 2 November). The pictures are kept in the folder.
set -uo pipefail

APP="${1:?the app bundle}"
OUT="${2:-build/settings-window}"
BINARY="$APP/Contents/MacOS/Lumen"
[[ -x "$BINARY" ]] || { echo "error: $BINARY is not there" >&2; exit 2; }
mkdir -p "$OUT"
status=0

window() {
  local name="$1"; shift
  local vault
  vault="$(mktemp -d "${TMPDIR:-/tmp}/lumen-settings-window.XXXXXX")"
  # A window left open by an earlier run would come back at launch, and not be the one opened now.
  rm -rf "$HOME/Library/Saved Application State/io.lumenbrowser.Lumen.savedState"
  PRIVACYBROWSER_VAULT_DIR="$vault" perl -e 'alarm shift; exec @ARGV' 120 \
    "$BINARY" --settings-window-check "$OUT/$name" "$@" -ApplePersistenceIgnoreState YES > "$OUT/$name.txt" 2>&1
  local code=$?
  rm -rf "$vault"
  echo "== $name (exit $code)"
  grep -E '^(SETTINGS-WINDOW (settings|titlebar|picture|sidebar rows|page rows|rows in)|PASS|FAIL)' "$OUT/$name.txt" | cut -c1-400
  return $code
}

dark_mode() {
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null 2>&1
}

window light || { echo "FAIL the Settings window in the light appearance"; status=1; }
if dark_mode true; then
  sleep 3
  window dark || { echo "FAIL the Settings window in the dark appearance"; status=1; }
  dark_mode false
else
  echo "FAIL this Mac's dark appearance could not be set (System Events): the window was not checked in it"
  status=1
fi
if window control --control; then
  echo "FAIL the control — the fix taken back — passed: the check cannot see a band"
  status=1
elif grep -q '^FAIL a band in the' "$OUT/control.txt"; then
  echo "PASS the control failed for a band, as it must"
else
  echo "FAIL the control failed, but not for a band"
  status=1
fi
exit $status
