#!/bin/sh
# Lumen's tools for a virtual machine's base system (docs/VM.md). Run once, inside the guest's
# macOS, by the account its first-run setup made — "Install Lumen Tools" in the shared folder.
#
# What it does, all of it in this machine and none of it on the Mac that runs it:
#   - signs in to this account automatically at start (a profile's machine opens at its desktop);
#   - turns off sleep, the screen saver's lock, the Spotlight index and automatic macOS updates (a
#     profile's disk is a copy of this one: gigabytes of updates would be fetched into every copy);
#   - installs the start-up helper (lumen-guest.sh, a LaunchDaemon) that gives each profile's
#     machine its time zone, language and name, opens Safari, and shuts macOS down when Lumen asks;
#   - says in the shared folder that the base is ready, and shuts the machine down.
set -u

TOOLS_VERSION=7
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST=/usr/local/lumen
PLIST=/Library/LaunchDaemons/io.lumenbrowser.guest.plist

say() { printf '%s\n' "$*"; }
fail() {
  say ""
  say "Stopped: $*"
  say "Close this window and open \"Install Lumen Tools\" again."
  exit 1
}

case "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" in
  VirtualMac*) ;;
  *) fail "this installer is for a Lumen virtual machine; it does nothing on a real Mac." ;;
esac
[ -f "$HERE/lumen-guest.sh" ] && [ -f "$HERE/io.lumenbrowser.guest.plist" ] \
  || fail "the tools' files are not beside this installer."

USER_NAME="$(/usr/bin/id -un)"
[ "$USER_NAME" != root ] || fail "run this as the account you made in macOS's setup, not as root."

say "Lumen — tools for this virtual machine"
say ""
say "This makes the machine the base of your virtual-machine profiles:"
say "  - it signs in to the account \"$USER_NAME\" by itself at start;"
say "  - sleep, the screen lock and automatic macOS updates are turned off;"
say "  - Lumen's start-up helper is installed (time zone, language, Safari's start page);"
say "  - the machine shuts down when this is done."
say ""
say "The password is kept in this machine to sign in by itself, and every machine made from it"
say "has it: it should be one made up for this machine, not your Mac's or any other you use."
say ""
printf 'Password of "%s" (the one you made for this machine): ' "$USER_NAME"
stty -echo 2>/dev/null
IFS= read -r PASSWORD
stty echo 2>/dev/null
say ""
[ -n "$PASSWORD" ] || fail "an empty password. The account needs one for automatic sign-in."
# To sudo on its standard input (printf is the shell's own: no command line carries it).
printf '%s\n' "$PASSWORD" | /usr/bin/sudo -S -p '' -v 2>/dev/null || fail "that password was not accepted."

# The start-up helper.
/usr/bin/sudo /bin/mkdir -p "$DEST" || fail "could not make $DEST."
/usr/bin/sudo /bin/cp "$HERE/lumen-guest.sh" "$DEST/lumen-guest.sh" || fail "could not copy the start-up helper."
/usr/bin/sudo /usr/sbin/chown root:wheel "$DEST" "$DEST/lumen-guest.sh"
/usr/bin/sudo /bin/chmod 755 "$DEST" "$DEST/lumen-guest.sh"
/usr/bin/sudo /bin/cp "$HERE/io.lumenbrowser.guest.plist" "$PLIST" || fail "could not install the start-up helper."
/usr/bin/sudo /usr/sbin/chown root:wheel "$PLIST"
/usr/bin/sudo /bin/chmod 644 "$PLIST"

# Automatic sign-in. Not possible while FileVault is on: the disk is then unlocked by a password
# typed at start.
AUTOLOGIN=0
if /usr/bin/fdesetup isactive 2>/dev/null | /usr/bin/grep -q true; then
  say "FileVault is on in this machine: it cannot sign in by itself."
else
  # sysadminctl takes the password as an argument or asks for it at the terminal ("-"); it does not
  # read it from its standard input. So it is an argument, for the moment the command runs, in
  # this new machine where nothing but the person's own setup runs yet — and it is a password made
  # up for the machine (above), which automatic sign-in keeps in the machine anyway.
  /usr/bin/sudo /usr/sbin/sysadminctl -autologin set -userName "$USER_NAME" -password "$PASSWORD" >/dev/null 2>&1
  if [ "$(/usr/bin/sudo /usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$USER_NAME" ]; then
    AUTOLOGIN=1
  fi
fi

# No sleep, no lock: the machine is a window on the Mac, which has its own.
/usr/bin/sudo /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1
/usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0 >/dev/null 2>&1
/usr/bin/sudo /usr/bin/defaults write /Library/Preferences/com.apple.screensaver idleTime -int 0 >/dev/null 2>&1
/usr/sbin/sysadminctl -screenLock off -password "$PASSWORD" >/dev/null 2>&1

# No Spotlight index: a machine is for Safari, and indexing its whole system at every first start
# keeps the Mac's processors busy — and warm — for a quarter of an hour, and grows every copy's disk.
/usr/bin/sudo /usr/bin/mdutil -a -i off >/dev/null 2>&1

# No automatic macOS updates (security data — XProtect and the like — stays on).
/usr/bin/sudo /usr/sbin/softwareupdate --schedule off >/dev/null 2>&1
for key in AutomaticDownload AutomaticallyInstallMacOSUpdates; do
  /usr/bin/sudo /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate "$key" -bool false
done
/usr/bin/sudo /usr/bin/defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

PASSWORD=""

# Lumen reads this when the machine has shut down.
STATUS="$HERE/lumen-status.env"
{
  printf 'LUMEN_TOOLS_VERSION=%s\n' "$TOOLS_VERSION"
  printf 'LUMEN_MACOS_VERSION=%s\n' "$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
  printf 'LUMEN_MACOS_BUILD=%s\n' "$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
  printf 'LUMEN_SAFARI_VERSION=%s\n' "$(/usr/bin/defaults read /Applications/Safari.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
  printf 'LUMEN_SETUP_DONE=1\n'
} > "$STATUS" || fail "could not write to the shared folder."

say ""
if [ "$AUTOLOGIN" = 1 ]; then
  say "Done. The machine shuts down in a few seconds; Lumen takes it from there."
  sleep 4
  /usr/bin/sudo /sbin/shutdown -h now
else
  say "Done, except automatic sign-in, which macOS did not accept."
  say "Turn it on in System Settings > Users & Groups > \"Automatically log in as\","
  say "then shut the machine down from the Apple menu. Without it, every profile's"
  say "machine asks for this account's password at start."
fi
