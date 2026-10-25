#!/bin/bash
# Makes the guest look like "just Safari": hides the Dock and the menu bar,
# desktop icons and widgets, and turns off hot corners, click-to-show-desktop
# and Stage Manager. Run as the logged-in user (admin), no root needed. The
# agent then keeps Safari's window filling the screen (POST /kiosk).
#
# Usage:
#   ./guest-kiosk.sh            # apply (skips quickly if already applied)
#   ./guest-kiosk.sh --revert   # back to the stock desktop
#   ./guest-kiosk.sh --print    # print the defaults calls; changes nothing
#
# The controller runs it over SSH (`bash -s`) when KIOSK=1. Changes to the
# menu bar setting may only take effect from the next login; the Dock and
# Finder ones apply at once (both are restarted).

set -euo pipefail

MODE=apply
case "${1:-}" in
  "") ;;
  --revert) MODE=revert ;;
  --print) MODE=print ;;
  *) echo "Usage: $0 [--revert|--print]" >&2; exit 1 ;;
esac

# domain key type value — bump VERSION when this list changes.
VERSION=1
SETTINGS=(
  "com.apple.dock autohide -bool true"
  "com.apple.dock autohide-delay -float 1000"
  "com.apple.dock autohide-time-modifier -float 0"
  "com.apple.dock show-recents -bool false"
  "com.apple.dock mru-spaces -bool false"
  "com.apple.dock wvous-tl-corner -int 1"
  "com.apple.dock wvous-tr-corner -int 1"
  "com.apple.dock wvous-bl-corner -int 1"
  "com.apple.dock wvous-br-corner -int 1"
  "NSGlobalDomain _HIHideMenuBar -bool true"
  "NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false"
  "com.apple.finder CreateDesktop -bool false"
  "com.apple.WindowManager EnableStandardClickToShowDesktop -bool false"
  "com.apple.WindowManager StandardHideDesktopIcons -bool true"
  "com.apple.WindowManager StandardHideWidgets -bool true"
  "com.apple.WindowManager StageManagerHideWidgets -bool true"
  "com.apple.WindowManager GloballyEnabled -bool false"
)
MARKER="$HOME/.pb-kiosk"

if [[ "$MODE" == apply && "$(cat "$MARKER" 2>/dev/null || true)" == "$VERSION" ]]; then
  echo "Kiosk settings already applied"
  exit 0
fi

for entry in "${SETTINGS[@]}"; do
  read -r domain key type value <<< "$entry"
  case "$MODE" in
    print) echo "defaults write $domain $key $type $value" ;;
    apply) defaults write "$domain" "$key" "$type" "$value" ;;
    revert) defaults delete "$domain" "$key" 2>/dev/null || true ;;
  esac
done

[[ "$MODE" == print ]] && exit 0

# Dock, Finder and the menu bar re-read their settings on restart.
for process in Dock Finder SystemUIServer; do
  killall "$process" 2>/dev/null || true
done

if [[ "$MODE" == apply ]]; then
  echo "$VERSION" > "$MARKER"
  echo "Kiosk settings applied"
else
  rm -f "$MARKER"
  echo "Kiosk settings reverted"
fi
