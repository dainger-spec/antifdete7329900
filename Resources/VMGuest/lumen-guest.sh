#!/bin/sh
# Lumen's start-up helper inside a virtual machine (docs/VM.md): the root LaunchDaemon
# io.lumenbrowser.guest, installed into the base system by install.sh and so present in every
# profile's machine, which is a copy of it.
#
# At each start it reads what Lumen left in the folder the machine shares with the Mac
# (lumen-settings.env: KEY=value lines, read as text and never run), and makes this macOS the
# profile's: its time zone, its language and region, its name, its appearance and accent colour,
# its desktop picture; then it opens Safari, says in the same folder what macOS and Safari this is (lumen-status.env),
# and from then on waits for Lumen's request to shut down (a file named lumen-shutdown), which it
# answers by quitting Safari and shutting macOS down, as the Apple menu would.
#
# Nothing here reaches the network. From the shared folder it reads those two names, Lumen's
# desktop picture for this machine's screen (lumen-wallpaper.png) — and a newer copy of itself
# (lumen-guest.sh), which it puts in its own place and starts: Lumen on the Mac is what made this
# machine, and a later Lumen's script needs no visit to the base system.

TOOLS_VERSION=3
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

# A newer copy of this script, from the Lumen that started the machine: taken once per start.
newer="$share/lumen-guest.sh"
if [ -n "$share" ] && [ -f "$newer" ] && [ "${LUMEN_GUEST_UPDATED:-0}" != 1 ]; then
  theirs="$(/usr/bin/sed -n 's/^TOOLS_VERSION=\([0-9][0-9]*\)$/\1/p' "$newer" 2>/dev/null | /usr/bin/head -n 1)"
  if [ -n "$theirs" ] && [ "$theirs" -gt "$TOOLS_VERSION" ]; then
    own=/usr/local/lumen/lumen-guest.sh
    if /bin/cp "$newer" "$own.new" 2>/dev/null && /usr/sbin/chown root:wheel "$own.new" && /bin/chmod 755 "$own.new" \
        && /bin/sh -n "$own.new" 2>/dev/null && /bin/mv -f "$own.new" "$own"; then
      log "updated to tools $theirs"
      LUMEN_GUEST_UPDATED=1 exec /bin/sh "$own"
    fi
    /bin/rm -f "$own.new" 2>/dev/null
  fi
fi

revision="" timezone="" language="" locale="" hostname="" start_url="" computer="" appearance="" accent="" open_safari=1
wallpaper=0
settings="$share/lumen-settings.env"
if [ -n "$share" ] && [ -f "$settings" ]; then
  revision="$(value LUMEN_REVISION "$settings")"
  timezone="$(value LUMEN_TIMEZONE "$settings")"
  language="$(value LUMEN_LANGUAGE "$settings")"
  locale="$(value LUMEN_LOCALE "$settings")"
  hostname="$(value LUMEN_HOSTNAME "$settings")"
  start_url="$(value LUMEN_START_URL "$settings")"
  computer="$(value LUMEN_COMPUTER_NAME "$settings")"
  appearance="$(value LUMEN_APPEARANCE "$settings")"
  accent="$(value LUMEN_ACCENT "$settings")"
  open_safari="$(value LUMEN_OPEN_SAFARI "$settings")"
  wallpaper="$(value LUMEN_WALLPAPER "$settings")"
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
only "A-Za-z0-9 '-" "$computer" || computer=""
case "$appearance" in light|dark|auto) ;; *) appearance="" ;; esac
case "$accent" in multi|-1|0|1|2|3|4|5|6) ;; *) accent="" ;; esac
[ "$open_safari" = 0 ] || open_safari=1
[ "$wallpaper" = 1 ] || wallpaper=0

# The colour of selected text that goes with an accent colour, as System Settings sets the two.
highlight() {
  case "$1" in
    -1) printf '%s' "0.847059 0.847059 0.862745 Graphite" ;;
    0) printf '%s' "1.000000 0.733333 0.721569 Red" ;;
    1) printf '%s' "1.000000 0.874510 0.701961 Orange" ;;
    2) printf '%s' "1.000000 0.937255 0.690196 Yellow" ;;
    3) printf '%s' "0.752941 0.964706 0.678431 Green" ;;
    4) printf '%s' "0.698039 0.843137 1.000000 Blue" ;;
    5) printf '%s' "0.968627 0.831373 1.000000 Purple" ;;
    6) printf '%s' "1.000000 0.749020 0.823529 Pink" ;;
  esac
}

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
# The name the person gave the computer, as Sharing shows it; the host name above goes with it.
[ -z "$computer" ] || /usr/sbin/scutil --set ComputerName "$computer" 2>/dev/null

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

# Lumen's desktop picture, as the app drew it for this machine's screen. It is set once for each
# picture: a person who then chooses another in the machine keeps theirs. A picture is kept under
# a name of its own (by its checksum) — macOS shows a changed file of the same name as the old one.
WALLPAPERS=/Users/Shared/Lumen
set_wallpaper() {
  [ "$wallpaper" = 1 ] && [ -n "$share" ] && [ -f "$share/lumen-wallpaper.png" ] || return 0
  sum="$(/usr/bin/cksum < "$share/lumen-wallpaper.png" 2>/dev/null | /usr/bin/cut -d ' ' -f 1)"
  only '0-9' "$sum" || return 0
  picture="$WALLPAPERS/wallpaper-$sum.png"
  [ ! -e "$picture.set" ] || return 0
  if [ ! -f "$picture" ]; then
    /bin/mkdir -p "$WALLPAPERS" && /bin/chmod 755 "$WALLPAPERS"
    /bin/rm -f "$WALLPAPERS"/wallpaper-*.png "$WALLPAPERS"/wallpaper-*.png.set 2>/dev/null
    /bin/cp "$share/lumen-wallpaper.png" "$picture" 2>/dev/null && /bin/chmod 644 "$picture" || return 0
  fi
  # By the system's own call for it, in the person's session: no other app is told to do it, so
  # nothing asks the person for a permission.
  done_it="$(as_user /usr/bin/osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("AppKit");
    var url = $.NSURL.fileURLWithPath(argv[0]);
    var screens = $.NSScreen.screens;
    var ok = screens.count > 0;
    for (var i = 0; i < screens.count; i++) {
      ok = $.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(url, screens.objectAtIndex(i), $.NSDictionary.dictionary, null) && ok;
    }
    return ok ? "set" : "not set";
  }' "$picture" 2>/dev/null)"
  if [ "$done_it" = "set" ]; then
    : > "$picture.set"
  fi
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
  # The system's look, which a page can read: set before Safari is opened, which takes it then.
  case "$appearance" in
    dark)
      as_user /usr/bin/defaults write -g AppleInterfaceStyle -string Dark
      as_user /usr/bin/defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null ;;
    light)
      as_user /usr/bin/defaults delete -g AppleInterfaceStyle 2>/dev/null
      as_user /usr/bin/defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null ;;
    auto)
      as_user /usr/bin/defaults delete -g AppleInterfaceStyle 2>/dev/null
      as_user /usr/bin/defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool true ;;
  esac
  case "$accent" in
    "") ;;
    multi)
      as_user /usr/bin/defaults delete -g AppleAccentColor 2>/dev/null
      as_user /usr/bin/defaults delete -g AppleHighlightColor 2>/dev/null ;;
    *)
      as_user /usr/bin/defaults write -g AppleAccentColor -int "$accent"
      as_user /usr/bin/defaults write -g AppleHighlightColor -string "$(highlight "$accent")" ;;
  esac
  # Kept per machine by macOS (by its hardware identifier), so not what the base system had: no
  # screen saver, which would lock a machine left alone behind a password nobody types here.
  as_user /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null
  # The desktop first: Safari opened before the Dock is there opens behind it. The picture
  # before the wait, so that the desktop appears with it — and after, for a session that was not
  # ready to take it.
  set_wallpaper
  /bin/sleep 4
  set_wallpaper
  if [ -n "$share" ] && [ -f "$settings" ] && [ "$open_safari" = 1 ]; then
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
