#!/bin/sh
# Lumen's start-up helper inside a virtual machine (docs/VM.md): the root LaunchDaemon
# io.lumenbrowser.guest, installed into the base system by install.sh and so present in every
# profile's machine, which is a copy of it.
#
# At each start it reads what Lumen left in the folder the machine shares with the Mac
# (lumen-settings.env: KEY=value lines, read as text and never run), and makes this macOS the
# profile's: its time zone, its language and region, its name; then it opens Safari, says in the
# same folder what macOS and Safari this is (lumen-status.env), and from then on waits for Lumen's
# request to shut down (a file named lumen-shutdown), which it answers by quitting Safari and
# shutting macOS down, as the Apple menu would.
#
# Nothing here reaches the network, and nothing is read from the shared folder but those two names.

TOOLS_VERSION=1
SHARE="/Volumes/My Shared Files"
OWN_MOUNT=/var/run/lumen-share
TAG=com.apple.virtio-fs.automount

log() { /usr/bin/logger -t lumen-guest "$*"; }

# value KEY FILE: the value of the first KEY= line.
value() { /usr/bin/sed -n "s/^$1=//p" "$2" 2>/dev/null | /usr/bin/head -n 1; }

# only CHARACTERS VALUE: true when VALUE is not empty and made of CHARACTERS alone.
only() {
  case "$2" in
    "") return 1 ;;
    *[!$1]*) return 1 ;;
  esac
  return 0
}

# The shared folder: macOS mounts it by itself; when it has not after a while, here.
share=""
tries=0
while [ "$tries" -lt 120 ]; do
  if [ -d "$SHARE" ] && /bin/ls "$SHARE" >/dev/null 2>&1; then
    share="$SHARE"
    break
  fi
  if [ "$tries" -ge 25 ]; then
    /bin/mkdir -p "$OWN_MOUNT"
    if /sbin/mount_virtiofs "$TAG" "$OWN_MOUNT" 2>/dev/null || /sbin/mount -t virtiofs "$TAG" "$OWN_MOUNT" 2>/dev/null; then
      share="$OWN_MOUNT"
      break
    fi
  fi
  /bin/sleep 1
  tries=$((tries + 1))
done
[ -n "$share" ] || log "the shared folder did not appear: this machine keeps the settings it has"

revision="" timezone="" language="" locale="" hostname="" start_url=""
settings="$share/lumen-settings.env"
if [ -n "$share" ] && [ -f "$settings" ]; then
  revision="$(value LUMEN_REVISION "$settings")"
  timezone="$(value LUMEN_TIMEZONE "$settings")"
  language="$(value LUMEN_LANGUAGE "$settings")"
  locale="$(value LUMEN_LOCALE "$settings")"
  hostname="$(value LUMEN_HOSTNAME "$settings")"
  start_url="$(value LUMEN_START_URL "$settings")"
fi
only 'A-Za-z0-9' "$revision" || revision=""
only 'A-Za-z0-9_+/-' "$timezone" || timezone=""
only 'A-Za-z0-9-' "$language" || language=""
only 'A-Za-z0-9_' "$locale" || locale=""
only 'A-Za-z0-9-' "$hostname" || hostname=""
case "$start_url" in
  http://*|https://*) only ']A-Za-z0-9:/?#@&=+,.~%_[-' "$start_url" || start_url="" ;;
  *) start_url="" ;;
esac
case "$timezone" in *..*|/*) timezone="" ;; esac

# The system's own settings: the time zone a page reads from Safari, and the machine's name.
if [ -n "$timezone" ] && [ -e "/var/db/timezone/zoneinfo/$timezone" ]; then
  /usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false
  /usr/sbin/systemsetup -settimezone "$timezone" >/dev/null 2>&1 \
    || /bin/ln -sfn "/var/db/timezone/zoneinfo/$timezone" /etc/localtime
fi
if [ -n "$hostname" ]; then
  for name in ComputerName LocalHostName HostName; do
    /usr/sbin/scutil --set "$name" "$hostname" 2>/dev/null
  done
fi

user=""
uid=""
as_user() { /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" "$@"; }

write_status() {
  [ -n "$share" ] || return 0
  {
    printf 'LUMEN_TOOLS_VERSION=%s\n' "$TOOLS_VERSION"
    printf 'LUMEN_MACOS_VERSION=%s\n' "$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
    printf 'LUMEN_MACOS_BUILD=%s\n' "$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
    printf 'LUMEN_SAFARI_VERSION=%s\n' "$(/usr/bin/defaults read /Applications/Safari.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
    [ -z "$1" ] || printf 'LUMEN_APPLIED_REVISION=%s\n' "$1"
    printf 'LUMEN_SETUP_DONE=1\n'
  } > "$share/lumen-status.env" 2>/dev/null
}

# The person's side — the language Safari tells sites, and Safari itself — once someone is signed
# in (automatic sign-in: at once; otherwise when the person has typed the password).
user_done=0
apply_for_user() {
  user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)"
  case "$user" in
    ""|root|loginwindow|_mbsetupuser) user=""; return 1 ;;
  esac
  uid="$(/usr/bin/id -u "$user" 2>/dev/null)"
  [ -n "$uid" ] || { user=""; return 1; }
  if [ -n "$language" ]; then
    as_user /usr/bin/defaults write -g AppleLanguages -array "$language"
    [ -z "$locale" ] || as_user /usr/bin/defaults write -g AppleLocale -string "$locale"
  fi
  # Kept per machine by macOS (by its hardware identifier), so not what the base system had: no
  # screen saver, which would lock a machine left alone behind a password nobody types here.
  as_user /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null
  # The desktop first: Safari opened before the Dock is there opens behind it.
  /bin/sleep 4
  if [ -n "$share" ] && [ -f "$settings" ]; then
    if [ -n "$start_url" ]; then
      as_user /usr/bin/open -a Safari "$start_url" 2>/dev/null
    else
      as_user /usr/bin/open -a Safari 2>/dev/null
    fi
  fi
  write_status "$revision"
  user_done=1
  return 0
}

quit_safari() {
  [ -n "$user" ] || return 0
  /usr/bin/pgrep -x Safari >/dev/null 2>&1 || return 0
  as_user /usr/bin/osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 &
  waited=0
  while [ "$waited" -lt 10 ] && /usr/bin/pgrep -x Safari >/dev/null 2>&1; do
    /bin/sleep 1
    waited=$((waited + 1))
  done
}

write_status ""
while :; do
  [ "$user_done" = 1 ] || apply_for_user
  if [ -n "$share" ] && [ -e "$share/lumen-shutdown" ]; then
    log "Lumen asked for a shutdown"
    /bin/rm -f "$share/lumen-shutdown" 2>/dev/null
    quit_safari
    /sbin/shutdown -h now
    exit 0
  fi
  /bin/sleep 2
done
