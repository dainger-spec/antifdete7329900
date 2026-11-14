#!/bin/sh
# Lumen's start-up helper inside a virtual machine (docs/VM.md): the root LaunchDaemon
# io.lumenbrowser.guest, installed into the base system by install.sh and so present in every
# profile's machine, which is a copy of it.
#
# At each start it reads what Lumen left in the folder the machine shares with the Mac
# (lumen-settings.env: KEY=value lines, read as text and never run), and makes this macOS the
# profile's: its time zone, its language and region, its clock and week, its name, its appearance
# and accent colour, its Dock and scroll bars, its desktop picture; then it opens Safari, says in the same folder what macOS and Safari this is (lumen-status.env),
# and from then on waits for Lumen's request to shut down (a file named lumen-shutdown), which it
# answers by quitting Safari and shutting macOS down, as the Apple menu would.
#
# Nothing here reaches the network. From the shared folder it reads those two names and Lumen's
# desktop picture for this machine's screen (lumen-wallpaper.png). A newer copy of itself
# (lumen-guest.sh) it takes from a second folder of the Mac's, which the Mac shares read-only and
# this script mounts where only root reaches it (TOOLS_TAG): Lumen on the Mac is what made this
# machine, and a later Lumen's script needs no visit to the base system.
#
# The shared folder is writable from inside the machine, by any process of the person's: what is
# in it is read as theirs. A script found there is not run (tools 7 on); a picture is read as the
# person; what this script writes there is written to a new file and moved into place, so that a
# link left in its place is replaced, not followed. What it keeps for itself is in a folder of
# root's (/Library/Application Support/Lumen), not in /Users/Shared.

TOOLS_VERSION=8
SHARE="/Volumes/My Shared Files"
OWN_MOUNT=/var/run/lumen-share
TAG=com.apple.virtio-fs.automount
TOOLS_TAG=io.lumenbrowser.tools
TOOLS_MOUNT=/var/run/lumen-tools

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

# Every profile's machine is, to its macOS, a Mac it has never seen: a hardware identity of its
# own. At the first sign-in on such a Mac, macOS shows the person its panes for a new Mac — and on
# recent macOS its "Welcome" screen, whose "Get Started" did not answer a click in a machine (a
# client's report, 14 November). The person signed in by itself (the base's account) has seen
# them all in the base's setup: they are marked seen for them here, at the start, before the
# sign-in. Keys macOS does not know are not read; nothing of it reaches the network.
quiet_setup_assistant() {
  who="$1"
  only 'A-Za-z0-9._-' "$who" || return 0
  /usr/bin/id -u "$who" >/dev/null 2>&1 || return 0
  version="$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
  build="$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
  for key in DidSeeCloudSetup DidSeePrivacy DidSeeSiriSetup DidSeeTouchIDSetup DidSeeScreenTime \
      DidSeeAppearanceSetup DidSeeAccessibility DidSeeActivationLock DidSeeApplePaySetup DidSeeAvatarSetup \
      DidSeeiCloudLoginForStorageServices DidSeeSyncSetup DidSeeSyncSetup2 DidSeeTermsOfAddress \
      DidSeeTrueTonePrivacy DidSeeIntelligence DidSeeLockdownMode DidSeeWelcome; do
    /usr/bin/sudo -u "$who" /usr/bin/defaults write com.apple.SetupAssistant "$key" -bool true 2>/dev/null
  done
  if only '0-9.' "$version"; then
    for key in LastSeenCloudProductVersion LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion \
        LastPreLoginTasksPerformedVersion; do
      /usr/bin/sudo -u "$who" /usr/bin/defaults write com.apple.SetupAssistant "$key" -string "$version" 2>/dev/null
    done
  fi
  if only 'A-Za-z0-9' "$build"; then
    for key in LastSeenBuddyBuildVersion LastPreLoginTasksPerformedBuild; do
      /usr/bin/sudo -u "$who" /usr/bin/defaults write com.apple.SetupAssistant "$key" -string "$build" 2>/dev/null
    done
  fi
  /usr/bin/sudo -u "$who" /usr/bin/defaults write com.apple.SetupAssistant LastPrivacyBundleVersion -string 9999 2>/dev/null
}
quiet_setup_assistant "$(/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"

# mounted DIRECTORY: true when a volume is mounted there (it is on another device than the folder
# it is in).
mounted() {
  [ -d "$1" ] || return 1
  here="$(/usr/bin/stat -f %d "$1" 2>/dev/null)"
  above="$(/usr/bin/stat -f %d "$1/.." 2>/dev/null)"
  [ -n "$here" ] && [ -n "$above" ] && [ "$here" != "$above" ]
}

# shared DIRECTORY: true when the directory is the folder shared with the Mac — a mounted volume,
# or a folder with Lumen's settings in it (which only Lumen writes). Not a folder of that name
# that a start cut short left behind: macOS then mounts the share beside it under another name,
# and what this script wrote into the leftover would keep it there for good.
shared() {
  [ -d "$1" ] && /bin/ls "$1" >/dev/null 2>&1 || return 1
  [ -f "$1/lumen-settings.env" ] || mounted "$1"
}

# The shared folder: macOS mounts it by itself; when it has not after a while, here. A copy of
# this script that a newer one took the place of hands the folder it found on, and a folder
# mounted here at an earlier run of the script is still there.
share=""
case "${LUMEN_GUEST_SHARE:-}" in
  "$SHARE"|"$SHARE 1"|"$OWN_MOUNT") ! shared "$LUMEN_GUEST_SHARE" || share="$LUMEN_GUEST_SHARE" ;;
esac
tries=0
while [ -z "$share" ] && [ "$tries" -lt 120 ]; do
  for place in "$SHARE" "$SHARE 1" "$OWN_MOUNT"; do
    if shared "$place"; then
      share="$place"
      break
    fi
  done
  [ -z "$share" ] || break
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

# A newer copy of this script, from the Lumen that started the machine: taken once per start —
# and only from the Mac's read-only folder for it, mounted here by root where nobody else can
# put anything. The shared folder above is not where it is taken from: anything in the machine
# can write there, and what is taken runs as root. (Lumen leaves a copy there too, for a machine
# whose script is older than tools 7: that one takes it from there once, and this one from then
# on.)
tools=""
if [ "${LUMEN_GUEST_UPDATED:-0}" != 1 ]; then
  [ ! -L "$TOOLS_MOUNT" ] || /bin/rm -f "$TOOLS_MOUNT"
  if /bin/mkdir -p "$TOOLS_MOUNT" 2>/dev/null && [ -d "$TOOLS_MOUNT" ] && [ ! -L "$TOOLS_MOUNT" ]; then
    /bin/chmod 700 "$TOOLS_MOUNT" 2>/dev/null
    if mounted "$TOOLS_MOUNT" || /sbin/mount_virtiofs "$TOOLS_TAG" "$TOOLS_MOUNT" 2>/dev/null; then
      tools="$TOOLS_MOUNT"
    fi
  fi
fi
newer="$tools/lumen-guest.sh"
if [ -n "$tools" ] && [ -f "$newer" ] && [ ! -L "$newer" ]; then
  theirs="$(/usr/bin/sed -n 's/^TOOLS_VERSION=\([0-9][0-9]*\)$/\1/p' "$newer" 2>/dev/null | /usr/bin/head -n 1)"
  if [ -n "$theirs" ] && [ "$theirs" -gt "$TOOLS_VERSION" ]; then
    own=/usr/local/lumen/lumen-guest.sh
    next="$(/usr/bin/mktemp "$own.XXXXXX" 2>/dev/null)"
    if [ -n "$next" ] && /bin/cp "$newer" "$next" 2>/dev/null && /usr/sbin/chown root:wheel "$next" && /bin/chmod 755 "$next" \
        && /bin/sh -n "$next" 2>/dev/null && /bin/mv -f "$next" "$own"; then
      log "updated to tools $theirs"
      LUMEN_GUEST_UPDATED=1 LUMEN_GUEST_SHARE="$share" exec /bin/sh "$own"
    fi
    [ -z "$next" ] || /bin/rm -f "$next" 2>/dev/null
  fi
fi

revision="" timezone="" language="" locale="" hostname="" start_url="" computer="" appearance="" accent="" open_safari=1
wallpaper=0 hours="" first_weekday="" dock_position="" dock_autohide="" dock_size="" scrollbars=""
start_url_2="" start_url_3="" start_url_4="" start_url_5="" start_url_6=""
settings="$share/lumen-settings.env"
if [ -n "$share" ] && [ -f "$settings" ] && [ ! -L "$settings" ]; then
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
  hours="$(value LUMEN_HOURS "$settings")"
  first_weekday="$(value LUMEN_FIRST_WEEKDAY "$settings")"
  dock_position="$(value LUMEN_DOCK_POSITION "$settings")"
  dock_autohide="$(value LUMEN_DOCK_AUTOHIDE "$settings")"
  dock_size="$(value LUMEN_DOCK_SIZE "$settings")"
  scrollbars="$(value LUMEN_SCROLLBARS "$settings")"
  start_url_2="$(value LUMEN_START_URL_2 "$settings")"
  start_url_3="$(value LUMEN_START_URL_3 "$settings")"
  start_url_4="$(value LUMEN_START_URL_4 "$settings")"
  start_url_5="$(value LUMEN_START_URL_5 "$settings")"
  start_url_6="$(value LUMEN_START_URL_6 "$settings")"
fi
only 'A-Za-z0-9' "$revision" || revision=""
only 'A-Za-z0-9_+/-' "$timezone" || timezone=""
only 'A-Za-z0-9-' "$language" || language=""
only 'A-Za-z0-9_' "$locale" || locale=""
only 'A-Za-z0-9-' "$hostname" || hostname=""
# page ADDRESS: the address if it is an http(s) one made of an address's characters; nothing else.
page() {
  case "$1" in
    http://*|https://*) ! only ']A-Za-z0-9:/?#@&=+,.~%_[-' "$1" || printf '%s' "$1" ;;
  esac
}
start_url="$(page "$start_url")"
start_url_2="$(page "$start_url_2")"
start_url_3="$(page "$start_url_3")"
start_url_4="$(page "$start_url_4")"
start_url_5="$(page "$start_url_5")"
start_url_6="$(page "$start_url_6")"
case "$timezone" in *..*|/*) timezone="" ;; esac
only "A-Za-z0-9 '-" "$computer" || computer=""
case "$appearance" in light|dark|auto) ;; *) appearance="" ;; esac
case "$accent" in multi|-1|0|1|2|3|4|5|6) ;; *) accent="" ;; esac
[ "$open_safari" = 0 ] || open_safari=1
[ "$wallpaper" = 1 ] || wallpaper=0
case "$hours" in 12|24) ;; *) hours="" ;; esac
case "$first_weekday" in 1|2|3|4|5|6|7) ;; *) first_weekday="" ;; esac
case "$dock_position" in bottom|left|right) ;; *) dock_position="" ;; esac
case "$dock_autohide" in 0|1) ;; *) dock_autohide="" ;; esac
case "$dock_size" in 16|[2-9][0-9]|1[01][0-9]|12[0-8]) ;; *) dock_size="" ;; esac
case "$scrollbars" in Automatic|WhenScrolling|Always) ;; *) scrollbars="" ;; esac

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

# put FILE TARGET: FILE, a new file of this script's, takes TARGET's place in one step, whatever was
# there: a link is replaced, never written through — nor followed into a folder it points to
# (mv -h; where mv has no -h, a link is removed first). A real folder in its place is left, and
# FILE is not put.
put() {
  /bin/mv -f -h "$1" "$2" 2>/dev/null && return 0
  [ ! -L "$2" ] || /bin/rm -f "$2"
  [ ! -d "$2" ] || return 1
  /bin/mv -f "$1" "$2"
}

# What this script says back, into the shared folder: written to a new file of its own and put in
# the status file's place, so that whatever was left there (a link) is replaced, not written
# through.
write_status() {
  [ -n "$share" ] || return 0
  said_file="$(/usr/bin/mktemp "$share/.lumen-status.XXXXXX" 2>/dev/null)" || return 0
  [ -n "$said_file" ] || return 0
  {
    printf 'LUMEN_TOOLS_VERSION=%s\n' "$TOOLS_VERSION"
    printf 'LUMEN_MACOS_VERSION=%s\n' "$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
    printf 'LUMEN_MACOS_BUILD=%s\n' "$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
    printf 'LUMEN_SAFARI_VERSION=%s\n' "$(/usr/bin/defaults read /Applications/Safari.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
    [ -z "$1" ] || printf 'LUMEN_APPLIED_REVISION=%s\n' "$1"
    [ -z "$wallpaper_state" ] || printf 'LUMEN_WALLPAPER_STATE=%s\n' "$wallpaper_state"
    [ -z "$wallpaper_note" ] || printf 'LUMEN_WALLPAPER_NOTE=%s\n' "$wallpaper_note"
    printf 'LUMEN_SETUP_DONE=1\n'
  } > "$said_file" 2>/dev/null
  /bin/chmod 644 "$said_file" 2>/dev/null
  put "$said_file" "$share/lumen-status.env" 2>/dev/null || /bin/rm -f "$said_file" 2>/dev/null
}

# Lumen's desktop picture, as the app drew it for this machine's screen. A picture is kept under a
# name of its own (by its checksum) — macOS shows a changed file of the same name as the old one.
#
# It is set at sign-in and looked at again a few times in the machine's first minute and a half:
# a machine at its first start is a Mac the system has not seen (new hardware, a new display),
# and what the system then settles on for its desktop can come after the picture was set. Once
# that time has passed with the picture in place it is left alone for good — a person who then
# chooses another in the machine keeps theirs.
#
# What came of it goes back to Lumen in the status file: LUMEN_WALLPAPER_STATE (off, none — no
# picture in the shared folder —, set, kept, failed) and, for a failure, what the system said.
#
# The pictures are kept in a folder of root's, which nobody else can write: root writes there.
# (Tools 6 and before kept them in /Users/Shared/Lumen, which anyone can write; a picture marked
# set there is taken as set, and nothing else is read from there.) The picture in the shared
# folder is read as the person — the folder is theirs to write, and a link there to a file only
# root may read must not become a picture anyone may read — at most 64 MB of it.
WALLPAPERS="/Library/Application Support/Lumen"
OLD_WALLPAPERS=/Users/Shared/Lumen
wallpaper_state=""
wallpaper_note=""
wallpaper_looks=0
picture=""
# wallpapers_ready: the folder for the pictures is there, a folder (not a link), root's, 755.
wallpapers_ready() {
  [ ! -L "$WALLPAPERS" ] || return 1
  /bin/mkdir -p "$WALLPAPERS" 2>/dev/null || return 1
  [ -d "$WALLPAPERS" ] && [ ! -L "$WALLPAPERS" ] || return 1
  /usr/sbin/chown root:wheel "$WALLPAPERS" 2>/dev/null
  /bin/chmod 755 "$WALLPAPERS"
}
set_wallpaper() {
  wallpaper_note=""
  if [ "$wallpaper" != 1 ]; then wallpaper_state=off; return 0; fi
  offered="$share/lumen-wallpaper.png"
  if [ -z "$share" ] || [ ! -f "$offered" ] || [ -L "$offered" ]; then wallpaper_state=none; return 0; fi
  sum="$(as_user /usr/bin/cksum "$offered" 2>/dev/null | /usr/bin/cut -d ' ' -f 1)"
  if ! only '0-9' "$sum"; then wallpaper_state=failed; wallpaper_note="the picture could not be read"; return 0; fi
  picture="$WALLPAPERS/wallpaper-$sum.png"
  if [ -e "$picture.set" ] || [ -e "$OLD_WALLPAPERS/wallpaper-$sum.png.set" ]; then wallpaper_state=kept; return 0; fi
  if ! wallpapers_ready; then
    wallpaper_state=failed; wallpaper_note="the folder for the picture could not be made"; return 0
  fi
  if [ ! -f "$picture" ] || [ -L "$picture" ]; then
    /bin/rm -f "$WALLPAPERS"/wallpaper-*.png "$WALLPAPERS"/wallpaper-*.png.set 2>/dev/null
    incoming="$(/usr/bin/mktemp "$WALLPAPERS/incoming.XXXXXX" 2>/dev/null)"
    # The copy is the picture whose checksum was taken: one changed meanwhile is not taken.
    if [ -z "$incoming" ] || ! as_user /usr/bin/head -c 67108864 "$offered" > "$incoming" 2>/dev/null \
        || [ "$(/usr/bin/cksum < "$incoming" 2>/dev/null | /usr/bin/cut -d ' ' -f 1)" != "$sum" ] \
        || ! /bin/chmod 644 "$incoming" || ! /bin/mv -f "$incoming" "$picture"; then
      [ -z "$incoming" ] || /bin/rm -f "$incoming" 2>/dev/null
      wallpaper_state=failed; wallpaper_note="the picture could not be copied into the machine"; return 0
    fi
  fi
  # By the system's own call for it, in the person's session: no other app is told to do it, so
  # nothing asks the person for a permission. A screen that already shows the picture is left.
  answer="$(as_user /usr/bin/osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("AppKit");
    var path = argv[0];
    var url = $.NSURL.fileURLWithPath(path);
    var workspace = $.NSWorkspace.sharedWorkspace;
    var screens = $.NSScreen.screens;
    var count = screens.count;
    if (!(count > 0)) { return "no screen to set it on"; }
    var answer = "kept";
    for (var i = 0; i < count; i++) {
      var screen = screens.objectAtIndex(i);
      var shown = "";
      try { shown = ObjC.unwrap(workspace.desktopImageURLForScreen(screen).path); } catch (e) { shown = ""; }
      if (shown === path) { continue; }
      if (!workspace.setDesktopImageURLForScreenOptionsError(url, screen, $.NSDictionary.dictionary, null)) { return "the system refused the picture"; }
      answer = "set";
    }
    return answer;
  }' "$picture" 2>"$WALLPAPERS/said")"
  # The answer is what the program returned; what the system printed beside it (it prints
  # warnings of its own) is only looked at when there is no answer to go by.
  case "$answer" in
    set|kept) wallpaper_state=set ;;
    *)
      wallpaper_state=failed
      [ -n "$answer" ] || answer="$(/usr/bin/head -n 3 "$WALLPAPERS/said" 2>/dev/null)"
      wallpaper_note="$(printf '%s' "$answer" | /usr/bin/tr '\n' ' ' | /usr/bin/tr -cd 'A-Za-z0-9 .,:()_/-' | /usr/bin/cut -c 1-110)"
      [ -n "$wallpaper_note" ] || wallpaper_note="no answer from the system"
      log "wallpaper: $wallpaper_note" ;;
  esac
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
  # The clock and the week, as Date & Time and Language & Region set them.
  case "$hours" in
    24)
      as_user /usr/bin/defaults write -g AppleICUForce24HourTime -bool true
      as_user /usr/bin/defaults delete -g AppleICUForce12HourTime 2>/dev/null ;;
    12)
      as_user /usr/bin/defaults write -g AppleICUForce12HourTime -bool true
      as_user /usr/bin/defaults delete -g AppleICUForce24HourTime 2>/dev/null ;;
  esac
  [ -z "$first_weekday" ] || as_user /usr/bin/defaults write -g AppleFirstWeekday -dict gregorian -int "$first_weekday"
  # When scroll bars show: an app takes it as it starts, so before Safari.
  [ -z "$scrollbars" ] || as_user /usr/bin/defaults write -g AppleShowScrollBars -string "$scrollbars"
  # The Dock: what it leaves of the screen is what a page is told is free. It is started again
  # only when something of it was changed — it takes its settings as it starts.
  dock_changed=0
  if [ -n "$dock_position" ] && [ "$(as_user /usr/bin/defaults read com.apple.dock orientation 2>/dev/null)" != "$dock_position" ]; then
    as_user /usr/bin/defaults write com.apple.dock orientation -string "$dock_position"
    dock_changed=1
  fi
  if [ -n "$dock_autohide" ] && [ "$(as_user /usr/bin/defaults read com.apple.dock autohide 2>/dev/null)" != "$dock_autohide" ]; then
    as_user /usr/bin/defaults write com.apple.dock autohide -bool "$([ "$dock_autohide" = 1 ] && echo true || echo false)"
    dock_changed=1
  fi
  if [ -n "$dock_size" ] && [ "$(as_user /usr/bin/defaults read com.apple.dock tilesize 2>/dev/null)" != "$dock_size" ]; then
    as_user /usr/bin/defaults write com.apple.dock tilesize -int "$dock_size"
    dock_changed=1
  fi
  [ "$dock_changed" = 0 ] || /usr/bin/killall Dock 2>/dev/null
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
      # The first page, and those after it: each in a tab of its own.
      set -- "$start_url"
      for more in "$start_url_2" "$start_url_3" "$start_url_4" "$start_url_5" "$start_url_6"; do
        [ -z "$more" ] || set -- "$@" "$more"
      done
      as_user /usr/bin/open -a Safari "$@" 2>/dev/null
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
ticks=0
while :; do
  [ "$user_done" = 1 ] || apply_for_user
  # The picture again at about 10, 20, 40 and 80 seconds after sign-in; then it is left for good.
  if [ "$user_done" = 1 ] && [ "$wallpaper_looks" -lt 4 ]; then
    ticks=$((ticks + 1))
    case "$ticks" in
      5|10|20|40)
        set_wallpaper
        wallpaper_looks=$((wallpaper_looks + 1))
        if [ "$wallpaper_looks" -ge 4 ] && [ "$wallpaper_state" = set ] && [ -n "$picture" ]; then
          : > "$picture.set" 2>/dev/null
        fi
        write_status "$revision" ;;
    esac
  fi
  if [ -n "$share" ] && [ -e "$share/lumen-shutdown" ]; then
    log "Lumen asked for a shutdown"
    /bin/rm -f "$share/lumen-shutdown" 2>/dev/null
    quit_safari
    /sbin/shutdown -h now
    exit 0
  fi
  /bin/sleep 2
done
