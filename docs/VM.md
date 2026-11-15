# Virtual machines

A virtual machine's profile is a whole Mac: its own macOS, with the real Safari in it, on a disk of
its own, in a window. Where an ordinary profile is a set of website data inside one macOS — this
Mac's — a machine has a system of its own: keychain, caches, DNS cache, serial number, network
card. Nothing of it is in the same operating system as another profile, and nothing a page reads is
changed by a script.

This page says what is built, how the pieces fit, what a machine costs, and — plainly — what is
not measured yet and what does not work.

## For the person

Virtual machines are part of the **Team** plan (`Entitlement.allowsVirtualMachines`: the plan
`team` on an active license, or any plan the server gives the `virtual_machines` feature). On
another plan the section says so and offers the plans' page; nothing is downloaded and no machine
starts — the model refuses (`VMCenter.isAllowed`), not only the buttons. Machines made while the
plan had them stay on disk and in the list, where they can be deleted. A development build has no
licensing, and has the machines.

1. Signed in, the Profiles window's sidebar has **Virtual Machines**. **Add Virtual Machines** says
   first what it takes (disk, memory, time), then:
2. asks Apple which macOS this Mac can run as a guest, and **downloads it from Apple's servers**
   into the vault's folder — about 25 GB. None of it is in Lumen's own download: the app stays the
   size it was. It comes over **six connections at once**, in chunks of 32 MB (`VMImageFetch`): a
   network that gives each connection only so much — far from Apple's servers, through a VPN,
   under a provider's shaping — gives six several times that (people's reports, 14 November: one
   connection was slow). The download can be paused, and goes on with the chunks that are not here
   yet — also after a quit, a lost connection or a restart of the Mac. **Or the person's own file:**
   "I have the file…" (on the opening screen, and beside a paused download) takes a restore image
   (`.ipsw`) they already have — downloaded by Lumen on another Mac, by a download manager ("Copy
   Apple's link" while Lumen downloads gives the address), or a colleague's — see "A file the person
   has" below;
3. installs macOS from it (10–20 minutes) into the **base system**; the downloaded image is
   removed when the base is set up (until then, starting over is an installation, not a download);
4. opens the base in a window, for macOS's own first-run setup (the country, an account) and
   **Install Lumen Tools**, which the person opens from the shared folder in the guest's Finder;
   the machine shuts down by itself when the tools are in. During this setup the base has **no
   network card**: macOS's setup then asks nothing of Apple's servers, is shorter by the screens
   that need them, and cannot hang waiting for them (the first run on a Mac, 13 November: with
   this Mac's connection the setup stood on a screen with its buttons off). "Open with Internet"
   is there for a setup that will not go on without one;
5. from then on **New Machine** makes a profile. Its machine is a copy-on-write clone of the base,
   made in seconds at its first start, with an identity of its own.

A build has the section only when it was made with `VM=1` (below). On a Mac with an Intel processor
the section says that macOS runs as a guest only on Apple silicon.

## What a machine costs

| | |
|---|---|
| Download | about 25 GB, once, from Apple; removed after the installation |
| Base system on disk | about 20–25 GB |
| Each machine on disk | what its macOS changes after the clone: usually 3–6 GB, growing with use |
| Memory | 3, 4, 6 or 8 GB per profile, only while it runs; a new machine gets 8 on a Mac with 24 GB or more, 6 with 16, 4 below |
| At once | **two** machines — Apple's limit for macOS guests on one Mac, enforced by the framework |
| Start | 20–40 seconds, as a Mac starts |

The disks are sparse files, and a machine's disk is an APFS clone of the base's (`clonefile`): the
blocks the two have in common are stored once. On a volume that cannot clone (not APFS) the disk is
copied whole — the full size of the base, per machine.

## The pieces

```
Sources/BrowserCore/VirtualMachines/   the model, platform-independent, unit-tested on Linux
  VMProfile.swift        a profile and the list (vms.bin, encrypted in the vault)
  VMDisplay.swift        screens of real Macs; what the setup needs (VMRequirements)
  VMLibrary.swift        where machines are on disk; how far the setup got
  VMDownload.swift       the resumable download's decisions (Range, If-Range), the chunk map
  VMImageFetch.swift     the download: several connections, chunk by chunk (tested on Linux)
  VMGuestSettings.swift  what the guest is told, what it says back
  VMHelperProtocol.swift the app's conversation with the helper
Sources/VMNetCore/                     the machine's network through a proxy (docs/VM_NETWORK.md)
Sources/LumenVM/                       the helper: Apple's Virtualization.framework
Sources/PrivacyBrowser/App/VirtualMachines/
  VMCenter.swift         the setup, the profiles, the machines running now
  VMHelperProcess.swift  one run of the helper
  VMImageDownloader.swift the download as the app has it: its failures in the person's language
Sources/PrivacyBrowser/UI/VirtualMachinesView.swift   the section, the setup's steps, the editor
Resources/VMGuest/                     what the base system's macOS gets
Resources/LumenVM.entitlements         the helper's one right
```

### The helper, `LumenVM`

Apple's Virtualization.framework is used directly — no third-party hypervisor, nothing downloaded
but Apple's own restore image. Everything that touches it is in one executable,
`Contents/MacOS/LumenVM`, signed with `com.apple.security.virtualization` **alone**: no keychain
group, no network extension's right, no relaxation of the hardened runtime. The app's own
executable and `LumenProfile` are signed exactly as in a build without machines; a machine that
fails takes nothing of the app with it.

The app starts the helper for each thing a machine is needed for and tells it what to do in **one
JSON line on its standard input** — never in arguments: the request carries the proxy's password.
The helper answers in JSON lines on its standard output and ends when the machine has:

| mode | what it does | events |
|---|---|---|
| `catalog` | asks Apple which macOS this Mac can run as a guest | `catalog` (address, version, build) |
| `install` | installs the restore image into the base's folder | `progress`…, `installed` |
| `run` | runs a machine in a window until its macOS has shut down | `started`, `traffic`…, `stopped` |

After the request the app may write `stop` (shut the guest down) or `kill` (end the machine now).
The end of the helper's input reads as `stop`: a machine does not outlive the app that started it,
and an installation the app is not there to take ends with it.

What the helper does about the Mac and the app around it:

- **The Mac logging out, restarting or shutting down** while a machine runs: the machine is shut
  down without a question and the helper ends when it has. (It used to ask "Shut down this
  virtual machine?" and answer the system "not now", which cancelled the logout.) A quit from
  the Dock still asks.
- **The app gone** (crashed, or ended): the machine is shut down as it is at a quit. What the
  helper says goes to a pipe nobody reads then; those writes fail quietly (`SIGPIPE` is ignored
  and the writes are the throwing kind) instead of ending the helper in the middle of the
  shutdown it had just begun.
- **Force Stop**: the helper is asked to end the machine; if it has not ended in eight seconds
  the app ends it with `SIGKILL` — the polite signal is one a running helper takes for another
  request to shut down, and a helper whose main thread is stuck took neither.
- **The base and a machine being made**: a machine not made yet is a copy of the base's disk,
  so it is not started while the base is open (checked again after its proxy was asked), and
  the base is not opened while such a machine is starting.

### A machine's identity

Each profile's machine has, of its own:

- a **machine identifier** (`VZMacMachineIdentifier`), made new when the machine is cloned — to the
  macOS inside, and to Apple's services, another Mac than the base and than every other profile's:
  another serial number, another hardware UUID;
- a **network card's address**, locally administered and random, kept with the profile;
- a **screen** from a list of real Macs (MacBook Air 13″ and 15″, MacBook Pro 14″ and 16″, iMac 24″,
  an external 1080p display): the guest's screen has that size in pixels and that density whatever
  the size of the window on this Mac — the window scales the picture, it never changes the screen
  (`automaticallyReconfiguresDisplay` is off);
- **8 processors** where this Mac has them (Safari tells a page at most 8), and the memory the
  profile says;
- speakers, and a microphone that hears nothing: no source is given to it, so nothing of this Mac
  is recorded.

The time zone, the language and the region are the guest system's own settings — set by the boot
script from the profile, not patched into a page. Safari in the guest is Apple's Safari, started as
the person's own.

### The network

| profile | where the machine's connections go |
|---|---|
| no proxy | made by the helper as this Mac's own apps make theirs (`VMNetDirectConnector`): ordinary sockets, which go through its VPN and by its routes — or, where the Mac's network settings name a proxy (a VPN tool in "system proxy" mode), through that proxy, as Safari on the Mac does. Sites see this Mac's address, or its VPN's. A VPN that answers names with private addresses of its own is followed into its tunnel (`docs/VM_NETWORK.md`). When connections fail one after another, the machine's row and its window say so, with the kind of failure and the helper's own words for it |
| a proxy | every connection of the guest — the whole macOS, not only Safari — goes through the profile's proxy, and there is no other way out |

In both, the machine's network card is a socket whose other end is `VMNetCore` in the helper: it
answers the guest's DHCP and DNS itself and ends the guest's TCP connections. **Apple's NAT for
virtual machines is not used.** It carries a guest's packets through a network of the system's
own, beside the apps' — and where the Mac runs a VPN or a proxy tool that takes the apps' traffic,
the guest's packets are not taken with it: on the first Mac this ran on (13 November) a machine
"through my network" had no internet at all, and macOS's first-run setup hung waiting for Apple's
servers. Connections made by the helper itself go wherever any app's do.

With a proxy the machine is **fail-closed by construction**: its card is not attached to any
network of this Mac, names are resolved by the proxy and never by this Mac, and each connection is
carried through the proxy (SOCKS5 or HTTP CONNECT). Without one, names are resolved by this Mac,
and a name that resolves to this Mac (any address of its, public ones included) or to a network
it is on is refused, as is an address written as a name. That holds for connections the helper
makes itself. Where the Mac's network settings name a proxy, the connection is asked of that
proxy by name, and where the proxy then connects is its decision: a proxy tool that sends a
public name to an address of the local network takes a machine there as it takes Safari — a page
in a guest is kept from the Mac's local network by this Mac's rules only so far as the tool keeps
to them (docs/VM_NETWORK.md). A proxy set by a configuration file (PAC, WPAD) is not followed, and
the machine then has no network, with its row saying why. A machine with a proxy of its own has
no way to this Mac's network at all. **UDP does not leave a machine**, with a proxy or without: QUIC
falls back to TCP, and WebRTC has no path that could show this Mac's address. Apple's software-update hosts are answered "no
such name", so a machine does not fetch gigabytes of updates through a paid proxy. docs/VM_NETWORK.md
has the details and the tests.

Before each start the proxy is checked, as a profile's is: where it comes out, and its time zone.
A machine whose proxy does not answer is not started. With "time zone and language follow the
proxy" the profile takes them from that check.

A proxy reached over TLS (`https://`) is not supported for machines yet; the editor does not offer
one, and `VMProfile.validate` refuses it. A proxy's "domains that go direct" are not applied in a
machine: nothing of a proxied machine goes direct.

### The guest's tools

While the base is set up, its window has a panel beside macOS's screen: what to press on each of
the setup's screens, the choices that matter in orange (no Apple ID, no FileVault, a password made
up for the machine, then Install Lumen Tools) — the app sends it as `texts["guide"]`, lines of
`# ` a title, `! ` a step that matters, `> ` a note. People chose what made a poor base with one
line above the screen to go by (14 November); how the base connects to the internet during its
setup does not matter to the machines, and the guide says so.

`Resources/VMGuest/` is put into the folder the base shares with the app — each file's bytes in a
new file, not a copy of the file: a copy keeps extended attributes, and a Lumen downloaded from the
internet may carry the download's quarantine on them, on which macOS in the machine would refuse
to run the installer or ask about it — and the person runs `Install Lumen Tools.command` there once
(it refuses to run on anything but a virtual Mac). Opened from Terminal it is the same:
`sh "/Volumes/My Shared Files/install.sh"`. It:

- first, before it changes anything or asks for the password, stops on the two choices of macOS's
  setup that make a poor base, and says in English and Russian what to do (tools 9): an Apple ID
  signed in (it would be in every machine made from this one — `MobileMeAccounts`), FileVault on
  (no machine could sign in by itself — `fdesetup isactive`);
- turns on automatic sign-in for the account the person made;
- turns off sleep, the screen saver's lock and automatic macOS updates;
- installs `lumen-guest.sh` as the root LaunchDaemon `io.lumenbrowser.guest`;
- writes `lumen-status.env` into the shared folder and shuts the machine down.

Every profile's machine is a clone of that system, so it has the daemon. At each start the daemon
reads `lumen-settings.env` from the shared folder — `KEY=value` lines, read as text, each value
checked against the characters it may have, **never run** — and applies the time zone, the
language and region (for the signed-in account), the computer's name; opens Safari (on the
profile's start page, if it has one); writes back which macOS and Safari this is; then waits for a
file named `lumen-shutdown`, which it answers by quitting Safari and shutting macOS down.

As it goes it says which step it is at (tools 13), in the status file: `LUMEN_STAGE` is `signin`
from its first word (it waits for the person's session), then `locale` (the language and region,
the keyboard), `look` (the appearance and accent, the clock and week, the scroll bars, the Dock),
`wallpaper` (Lumen's picture, when the profile has it), `safari` and `ready`. Once this start's
settings are in — the language and region written for the signed-in person, the first picture set
and the four seconds the desktop is given — it names them (`LUMEN_READY_REVISION`, this start's
`LUMEN_REVISION`), **before** it opens Safari, which then starts in them; not after the picture's
later looks. `LUMEN_APPLIED_REVISION` is written after Safari was opened, as before. The machine's
window keeps its screen behind a cover until then ("The start's cover" below). A base with tools 7
to 12 needs nothing done to it: the app puts this script into the tools' folder at every start,
and the older script there takes it and runs it before it reads the settings — so the first start
with this Lumen already says its steps. (Tools 2 to 6 take it from the shared folder, once; tools 1
must be installed again.)

Before all that — at the start, before the automatic sign-in — it marks macOS's panes for a new
Mac as seen for the person who signs in by themselves (`com.apple.SetupAssistant`: `DidSee…`,
`LastSeen…` with this macOS's version and build; tools 8). Every profile's machine is a Mac its
macOS has never seen, a hardware identity of its own, and at its first sign-in macOS showed them
again — on recent macOS its "Welcome" screen, whose "Get Started" did not answer a click in a client's
machine (14 November). The person saw them all in the base's setup. Not measured on a Mac yet:
which of the keys that screen reads.

Shut Down in the app (or closing the machine's window) asks that way first — no question on the
guest's screen — then presses the virtual power button after 20 seconds, and ends the machine after
a minute.

The shared folder is where macOS mounts it (`/Volumes/My Shared Files`), and the script takes a
folder for it only if a volume is mounted there or Lumen's settings are in it — not a folder of
that name a start cut short left behind, which it would otherwise write its status into and so
keep there, with the real share mounted beside it under another name from then on. Where macOS
has not mounted the share after 25 seconds the script mounts it itself; a copy of the script that
a newer one takes the place of hands the folder it found on (tools 6).

The shared folder is writable from inside the machine — by any process of the person's there,
not only by root — and the daemon runs as root, so it treats what is in the folder as the
person's (tools 7):

- A newer copy of the script is taken **only** from a second folder the helper gives the machine
  read-only (`VMLibrary.MachineFiles.tools`, virtio-fs tag `io.lumenbrowser.tools`), which the
  daemon mounts itself at `/var/run/lumen-tools` where only root reaches it. The app puts the
  script there at every start. A script found in the shared folder is not run, whatever its
  version: the guest cannot write the read-only folder, so an update still comes only from the
  Mac. (The app also leaves the script in the shared folder, where a machine with tools 6 or
  older looks: that machine takes it from there once, and from then on only from the tools'
  folder. A machine with tools 6 is as exposed to a planted script as it was until that start.)
- What the daemon keeps for itself — the desktop pictures, what the system said — is in
  `/Library/Application Support/Lumen`, a folder of root's (755), not in `/Users/Shared`, which
  anyone can write. Files are made with `mktemp` and moved into place.
- The picture in the shared folder is read as the signed-in person (a link there to a file only
  root may read does not become a picture anyone may read), at most 64 MB, and taken only if its
  checksum is the one it had when it was looked at. A link in the picture's or the settings'
  place is not read.
- The status file is written to a new file in the shared folder and moved into place: a link left
  in its place is replaced, not written through or followed into a folder.

On the Mac's side the app reads what the guest writes there (its status, the picture's marker)
with `VMShareFile`: no link followed, no pipe waited on, a regular file of a few kilobytes at
most, off the main thread; anything else is ignored and logged by its kind.

## A machine's settings

| | |
|---|---|
| Name, note, colour in the list | the app's own |
| Proxy | every connection of the machine through it; or none: this Mac's connection |
| Blocked sites | names the machine's network answers "no such name" for — the whole macOS, not Safari alone — beside the app's own list (Apple's update hosts) |
| Network card address | the machine's own (MAC), random when it is made; may be written or drawn anew |
| Time zone, language | with a proxy: from where the proxy comes out, at every start, or set by hand. Without one, the person's choice of three: this Mac's time zone (the language as it is in the machine); those of the country **this Mac's own connection** comes out in — its VPN's, when one is on — found at every start by a request from this Mac to a service that says where an address is, which is why it is a choice and not the rule (no answer: the machine starts with what it had, and its row says so); or set by hand |
| Region | with a language set by hand: the country whose formats the system uses ("en" in "DE": English as in Germany) |
| Clock, first day of the week | 12 or 24 hours; Monday, Sunday or Saturday; or as the region has them |
| Screen | a real Mac's, at its default size or at "More Space"; external displays |
| Memory | 3, 4, 6 or 8 GB, and 12 or 16 where the Mac keeps 8 for itself. A new machine gets what the Mac can spare (`VMRequirements.recommendedMemoryGB`: 8 on a Mac with 24 GB or more, 6 with 16, 4 below); with 4, macOS in it stutters once a few pages are open, and the editor says so |
| Processor | as a Mac (8 cores — what a page of any Mac of today sees), or 4 or 6: lighter on this Mac, and fewer than a Mac has |
| Sound | heard on this Mac, or not (the machine keeps its speakers either way) |
| Appearance | light, dark or auto: what a page reads as `prefers-color-scheme` |
| Accent colour | macOS's nine; a new machine gets one at random, as Macs differ in theirs |
| Computer's name | as Sharing shows it |
| Scroll bars | while scrolling, always, or by the pointing device. Left to the system a machine's always show — its pointer is a mouse to macOS — and take a strip of every page's width, which a page can measure and no MacBook has; a new machine with a MacBook's screen gets "while scrolling" |
| Keyboard layout | the base's, as chosen in its setup and the same in every machine; by the machine's language (`VMKeyboardLayout`: U.S., British, German, French, Spanish and Russian where the country's own is known for certain, the plain Latin "ABC" for other Latin-letter languages and countries, the base's left for the rest); or one of them by name. A new machine gets "by the language" |
| Dock | bottom, left or right; always shown or hiding; small, medium or large. What it leaves of the screen is what a page is told is free (`screen.availWidth`, `availHeight`) |
| Wallpaper | Lumen's eclipse, drawn by the app for the machine's screen pixel for pixel (`VMWallpaper`; no picture is carried in the app); or the picture left as it is in the machine |
| At start | Safari opened or not; its start page, and up to five more, each in a tab; the window full screen |
| Instant wake | off unless chosen. Closing the machine keeps it as it is, and opening it brings it back in seconds ("Instant wake" below). Such a machine has no sound |
| Browser mode | off unless chosen. The machine is shown as a browser: Safari over its whole screen, the menu bar and the Dock out of sight ("Browser mode" below) |

Those of the guest's own system are applied in it by the boot script and need **tools 2** (the
wallpaper: tools 3; the region's clock and week, the scroll bars, the Dock and the pages after
the first: tools 5; the keyboard: tools 10, `VMGuestTools.version`); a base set up with tools 1 says so in the list and in the
editor, and running Install Lumen Tools in the base again updates it. From tools 2 on, the boot
script takes a newer copy of itself from the shared folder at a machine's start (the app puts its
own there), so later versions — tools 3 among them — need no visit to the base
(`VMGuestTools.mustBeInstalledAgain`).

The wallpaper is a PNG the app leaves in the shared folder (`lumen-wallpaper.png`) at a machine's
start, once for a screen size. The boot script copies it into the guest under a name made of its
checksum (macOS shows a changed file of the same name as the old one) and sets it in the person's
session by the system's own call (`NSWorkspace`, from `osascript` — no other app is told to do
it, so nothing asks for a permission). It is set at sign-in and looked at again about 10, 20, 40
and 80 seconds later (tools 4): a machine at its first start is a Mac the system has not seen,
and what it settles on for the desktop can come after the picture was set. After that it is left
alone for good — a person who then chooses another in the machine keeps theirs. What came of it
is said back in the status file (`LUMEN_WALLPAPER_STATE`, and `LUMEN_WALLPAPER_NOTE` with the
system's words for a failure), which the app reads while the machine runs: a picture that was
not set is said in the machine's row, and so is a machine made with the first tools, whose boot
script takes no newer one.

### What the base's region leaves behind, and what the system has (tools 10)

A machine whose language follows its proxy is given the language and the locale. Three things of
the base's region stayed behind that, found by reading the script against what macOS keeps (not
on a machine: none could be run here):

- **The keyboard's layouts** (`com.apple.HIToolbox`) are the person's, chosen in macOS's setup: a
  base set up in Russian gave every machine a Russian layout, whatever its language. The setting
  above writes them (`AppleEnabledInputSources`, `AppleSelectedInputSources`,
  `AppleInputSourceHistory`, `AppleCurrentKeyboardLayoutInputSourceID`) — once per choice, noted in
  the person's `io.lumenbrowser.guest` — and macOS takes them at sign-in: in use from the
  machine's **next** start, which the status says (`LUMEN_KEYBOARD_STATE=next`) and the row repeats.
  A machine with instant wake is woken, not started, so its next Close is a shutdown, once ("Instant
  wake" below).
- **What macOS wrote down for the old region**: its units and temperature scale
  (`AppleMeasurementUnits`, `AppleMetricUnits`, `AppleTemperatureUnit`), its own formats of dates
  and numbers (`AppleICU…`), its clock and week. With only `AppleLocale` changed they stood: a
  machine in the United States with centimetres and Celsius. They are removed once for each locale
  a machine is given (noted the same way), as System Settings does when the region is changed;
  the profile's own clock and week are written after, and what the person changes in the machine
  afterwards is kept.
- **Whether macOS took it at all** was assumed. The script now reads the time zone
  (`/etc/localtime`), the person's first language and their locale back from the system into the
  status file (`LUMEN_TIMEZONE_NOW`, `LUMEN_LANGUAGE_NOW`, `LUMEN_LOCALE_NOW`), and the app
  compares them with what it asked for (`VMGuestStatus.differences(from:)` — only once the script
  says it applied these very settings): a difference is said in the machine's row.

What was looked at and needs nothing: the network (no DNS query, UDP or IPv6 leaves, by
`docs/VM_NETWORK.md`), where the time zone and language come from (the proxy's exit, looked up
anew at every start, not the last check in the list), the clock (the host's; automatic time zone
is switched off). The layouts' numbers and names are macOS's own, as known; that a machine takes
them, and the units, is to be seen on a Mac.

## Instant wake

A machine's start is its macOS's: half a minute to the desktop, and everything in it closed when
it was shut down. With **instant wake** on (a profile's setting, off unless chosen) closing the
machine *saves* it instead — its memory, as Apple's framework writes it
(`VZVirtualMachine.saveMachineStateTo`, macOS 14) — and its next start brings that back
(`restoreMachineStateFrom`, then `resume`): the same pages, the same place, in seconds.

What holds it together, in `MachineRunner` and `VMSavedState`:

- **A state is one disk's, at one moment.** A machine's memory, woken on a disk that has gone on
  without it, would write what it remembers over what is there. So the state is used by the next
  start or removed by it, and removed *before* the machine runs again, taken or not; and beside
  it lies a note (`state.json`) of the disk as it was left when the machine had stopped after the
  save — its length and the time of its last write. A disk that is not exactly that is not this
  state's (`VMWakeRefusal.stale`), and the machine starts anew, as after a Mac lost power.
- **A state is one machine's.** The note carries the request's `stateStamp`: the hardware the
  framework is told of (processors, memory, screen, network card) and the revision of the settings
  the machine's macOS starts with. Anything of them changed — more memory, another language, a
  proxy that came out in another time zone — and the machine starts anew (`.changed`), so that
  the change takes; the row says why. What is this Mac's side only (the name, what is blocked,
  the proxy's address) is not in the stamp.
- **What can be saved.** The framework saves a Mac's own trackpad and keyboard, a disk, a network
  card and shared folders — and refuses a machine with sound, with the framework's source of
  random numbers, or with the USB pointer (`validateSaveRestoreSupport`). A machine with instant
  wake is made without them (`MachineConfiguration`): it is **silent**, which the setting says. A
  machine the framework still refuses is shut down when closed, as before, and the row says so
  (`.unsupported`).
- **Nothing is lost on the way.** A save that fails (the machine cannot be paused, the framework
  says no) is no reason to lose what is open in it: the machine goes on and is shut down as a Mac
  is. "Shut Down macOS" in the row's menu and in the window's is a real shutdown; "Start Anew…"
  gives a sleeping machine's state up, after a question.
- **Closed while it wakes.** For the seconds a wake takes (the state read, then the machine
  resumed) it can be neither paused nor saved. A close in that time — its window, the row's Close,
  Lock, Quit, this Mac's logout or shutdown — is kept for when it is awake, and the machine is put
  to sleep again then; it is not shut down, and its state is not removed for it. A state the
  framework does not take leaves nothing to keep: the machine, which never ran, is then not
  started. A wake that has not ended in 45 seconds is not waited for (the app gives a machine 75 on
  Lock and Quit): the helper ends, and a state not yet taken stays for the next start.
- **What macOS takes only at a start.** A keyboard layout and browser mode's menu bar are written
  after sign-in and taken at the next one (the status says `LUMEN_KEYBOARD_STATE=next`,
  `LUMEN_MENU_BAR_STATE=next`), and a machine put to sleep is woken, never started. So while one of
  them waits, the row's Close is "Shut Down" and says why, and the window's close asks — shut down
  this once, or keep it as it is; Lock, Quit, this Mac's shutdown and the window's "Close and Keep"
  put it to sleep as always, and it waits on. A machine started anew has what the macOS before it
  wrote: a status file from before that start is not taken for one about the macOS running now
  (`VMGuestStatus.asOf`, by the file's time).
- **The network.** The guest's connections are this process's and end with it: woken, the guest
  finds them reset and opens new ones. What it still holds are the stand-in addresses its DNS was
  given for names; the network takes those back by the same addresses (`VMNetConfiguration.knownNames`,
  kept in the note — a machine's browsing, beside its memory, which holds the same and more).
- **The clock.** A woken machine has the clock of the moment it was put to sleep. The helper
  leaves a word in the shared folder (`lumen-woke`), and the boot script — which went on where it
  was — asks for the time then (`sntp -sS`, tools 11); the machine's network answers every such
  question with this Mac's clock, and nothing leaves (docs/VM_NETWORK.md).

A sleeping machine takes about as much disk as it has memory. Lock, Quit and this Mac's own
shutdown put such a machine to sleep too — faster than shutting it down.

Not run on a Mac: that the framework takes this set of devices (it is the set other tools use
for it), how long a save and a wake take, and that `sntp` sets the clock as written.

## Browser mode

A machine is a Mac in a window: a desktop, a Dock, a menu bar, Safari somewhere in it. In
**browser mode** (a profile's setting, off unless chosen) it is shown as a browser:

- its macOS keeps the menu bar and the Dock out of sight (`_HIHideMenuBar`, the Dock's hiding;
  tools 11 — noted beside the person's settings, so that a machine no longer shown so gets them
  back), and Safari is opened whatever else the profile says. The menu bar takes it at the next
  sign-in, which the status says (`LUMEN_MENU_BAR_STATE=next`, tools 12): with instant wake the
  machine is shut down once for it, as for a keyboard layout;
- when the boot script says it has opened Safari (the status file), the helper presses
  Control-Command-F on the machine's own keyboard — events made for the machine's view, as a
  person's are; nothing in the guest is asked for a permission — which puts Safari over the
  machine's whole screen;
- until then the machine's screen is behind a cover with its name (a click takes it away; two
  minutes do too), so that the sign-in and the desktop are not what the person opened.

With instant wake a machine in browser mode opens as a browser window in seconds, with no cover:
it is as it was closed. "Safari Full Screen (in the Machine)" in the row's menu and "Full Screen
in the Machine" in the window's press the same key again — for a Safari that was not in front
when it was pressed, or to leave full screen.

Not run on a Mac: that the machine's view takes events made here as it takes a person's, and how
the menu bar's setting reads on the newest macOS. The key is a toggle: a Safari that macOS
itself brought back full screen would leave it; the menu's command puts it back.

## What machines have in common

Nothing of one machine's data, network or identity is another's. But every machine is a copy of
one base system, and this is what that means:

- **What was in the base when a machine was made is in the machine.** The account, its password,
  the system's settings — and whatever Safari in the base held. A site opened in the base leaves
  its cookies in every machine made after. The base is set up without a network for that reason
  too, and both the base's window and the list say not to browse in it. The account's password
  is kept in the machine for automatic sign-in (macOS's own `/etc/kcpassword`, which is
  obfuscated, not encrypted) and is in every machine: the setup's steps, the base's window and
  the installer ask for a password made up for the machine, not the Mac's or one used anywhere
  else. The installer gives it to `sudo` on standard input; `sysadminctl`, which reads it from no
  input, gets it as an argument for the moment it runs.
- **The same Mac, as far as a page can tell.** The same macOS and Safari, the same fonts, the same
  virtual GPU — as two Macs of one model and one macOS are the same to a page. What differs is
  what the profile sets: the screen, the time zone and language, the appearance and accent, and
  where the connection comes from. Whether the virtual GPU sets machines apart from real Macs as a
  class is not measured (below).
- **Without a proxy, the same address**: this Mac's.
- **Not shared**: disks (a clone's writes are its own), machine identifiers and serial numbers,
  network cards, the networks themselves (each machine's is its own, with nobody on it but the
  gateway — machines cannot reach each other), the folders they share with the app, the helper
  processes.

## On disk

```
<vault folder>/VirtualMachines/
  base.json               which macOS the base is, and how far its setup got
  base/                   disk.img, aux.img, hardware-model.bin, machine-id.bin, share/
  machines/<profile id>/  the same, per profile: the disk a clone of the base's
  downloads/              Apple's restore image while it is fetched (removed after the installation)
```

**The disks are not encrypted by the vault.** They are tens of gigabytes that the guest's macOS
writes all the time; sealing them as a profile's data is sealed would mean decrypting and
re-encrypting gigabytes at every start and stop. What protects them is what protects a Mac's disk:
FileVault on this Mac. The interface says so under the machines' list, and the Help topic does.
The profiles' own settings — names, proxies with their passwords — are in the vault (`vms.bin`,
encrypted like the proxy list), and are not readable while it is locked. The folder is left out of
Time Machine.

Lock and Quit shut the machines down first (`VMCenter.stopAll`) and wait for them.

A machine's disk is deleted by one path, `VMCenter.deleteMachineBecauseThePersonAsked`, called only
from the machines' own Delete confirmation (`scripts/check_deletion_paths.py` holds the code to
it), never while the machine runs. Removing the base system (⋯) leaves the machines: each has its
disk.

Machines are this Mac's: not synced, not in a profile's export, and not reachable through the
automation API yet.

## How smooth a machine is

A guest's macOS is drawn by Apple's paravirtual graphics and is not as smooth as the Mac's own;
what was in this app's hands, and was found slowing a machine on a person's Mac (13 November):

- **Memory.** With 4 GB, macOS with Safari is short of memory once a few pages are open, and
  works from its disk. A new machine now gets what the Mac can spare, and the editor says when a
  machine has less.
- **The disk's "write this down now".** The framework's default answers each of the guest's
  flushes by making the Mac's drive empty its own cache (`F_FULLFSYNC`) — tens of milliseconds
  each, many times a second, with the guest standing still. The disk is attached with
  `synchronizationMode: .fsync` instead. What is given up: if the Mac loses power — not if the
  app or the machine ends — the guest's last seconds of writes may not be on the drive.
- **App Nap.** macOS rests a process whose window is covered; the guest's processors are that
  process's. The helper holds an activity (`userInitiatedAllowingIdleSystemSleep`,
  `latencyCritical`) for as long as it runs; the Mac may still sleep when idle.
- **A machine's first start** is slower than its later ones: to its macOS it is a Mac it has not
  seen, and it rebuilds what it keeps per Mac. Spotlight's index is off in machines (the tools).

Not measured: how much each of these is worth on a given Mac.

## The download

`VMImageFetch` (BrowserCore) fetches the restore image in chunks of 32 MB, six at a time, each a
`Range` request on a URLSession of its own: one session would carry them all on one HTTP/2
connection, which is no faster than one request. The partial file has the whole length from the
start; a chunk counts only when every byte of it was written, and the chunks that are here are
kept in `restore.json` (`VMChunkMap`, runs of indexes), written at most once a second and at once
at a pause. The setup shows what the chunks that are here come to, not the partial file's length.

- The first request asks for the first chunk; its answer says the file's length and its validator
  (a strong `ETag`, else `Last-Modified`). Every other chunk is asked for under `If-Range`: a file
  Apple replaced meanwhile comes back whole (200), and the download starts over (twice at most,
  then it says so) rather than glue two files together.
- A download of one stream from before (no chunk map) counts the chunks its partial file holds
  whole.
- A server that answers the first request with 200 has no ranges: the whole file comes in one
  stream, which starts over if it breaks.
- A chunk that does not come whole is asked for again after a moment; a network that brings
  nothing again and again is given up on, with what is here kept. A server's own trouble (5xx,
  408, 429) is tried again; any other refusal is said.
- The connections go the way any app's do on this Mac — its VPN, its system proxy.

### A file the person has

"I have the file…" opens a file panel for an `.ipsw`. `VMImageImport.problem` first tells, without
Apple, what is no restore image (not a file, smaller than 1 GB, not a ZIP archive — every `.ipsw`
is one). Then the helper loads it as the installer would (`inspect`, a `catalog` event with the
file's macOS and build) and says whether it runs in a virtual machine on this Mac; Apple's
installer verifies it again as it installs. It is then cloned into the download's place where the
volume can (APFS, the same volume: no room taken, at once) and copied otherwise — into a file of
its own (`restore.ipsw.importing`), put in the image's place only when whole, the room checked
first. A paused download of Lumen's own is set aside only then. The person's file is never moved
or changed; the copy is removed with the downloaded image once the base is set up. A copy can be
called off (Cancel) and leaves things as they were.

`Tests/BrowserCoreTests/VMImageImportTests.swift`: what is no restore image said before Apple is
asked, the file copied into the image's place with the person's own left as it was, a clone or a
copy the same, a paused download set aside only once the file is whole (and kept when the copy is
called off), a file that is not there.

## What is not measured, and what does not work

- **How a machine looks to a site that studies the device.** Safari in the guest is real and
  nothing is injected, but the guest's graphics are Apple's paravirtual GPU, not a Mac's own.
  **WebGL, measured** (the owner, 14 November, browserleaks.com/webgl in a machine's Safari 27.2
  and in the same Mac's own Safari 27.2): the unmasked renderer is "Apple GPU" in both — Safari
  names no graphics card to a page —, every limit shown is the same, and so are the report's hash
  (97C494A4D0C794F1C38D869698CD4F4A) and the drawn image's (52497E308A4259F66BF07A8977E40D65).
  By WebGL a machine is that Mac. **Not measured**: WebGPU, the 2D canvas, audio, timing — no
  claim is made of them, and "cannot be told from a Mac" is not said.
- **No camera.** A guest has no camera device; a site that asks for one finds none.
- **UDP through a proxy**: none, by design (above). A site that needs WebRTC media will not have it
  in a proxied machine.
- **macOS updates** are off in the machines. Safari in them is the base's until the base is set up
  again from a newer macOS; machines made before keep theirs.
- **Two machines at once**, and Apple silicon only. A sandboxed build has no machines.
- **Apple's license** allows macOS in virtual machines on Apple hardware for development, testing
  and personal non-commercial use (macOS SLA, the section on virtualization). The Help topic says so.

## Building and checking

```
VM=1 SANDBOX=0 scripts/build-app.sh    # the helper beside the app's executable, the tools in Resources
VM=check scripts/build-app.sh          # builds the helper and starts it once (CI); the app is as without it
```

`VM=1` signs `LumenVM` under the identifier `<bundle id>.VirtualMachine` with
`Resources/LumenVM.entitlements`, reads the signature back (the right is there; no keychain
entitlement, no relaxation, no `get-task-allow`), and starts it once (`--check`). The virtualization
right is not a restricted entitlement: a Developer ID signature carries it without a provisioning
profile. `scripts/release.sh` passes `VM` through to the build.

What is checked where:

- `Tests/BrowserCoreTests/VirtualMachineTests.swift` (Linux and macOS): the profile list's format
  and its tolerance of a later version's, validation, the download's decisions for every answer a
  server gives, the settings file's text and what it refuses, the helper protocol's round trip.
- `Tests/BrowserCoreTests/VMImageFetchTests.swift` (Linux and macOS): **the download itself**,
  against a file server on loopback that speaks ranges as Apple's does and can be told to be
  worse: the file whole over several connections (and no more than it was given), a file smaller
  than a chunk, a paused download going on with only the chunks it did not have, a download of
  one stream from before taken up at its whole chunks, a file replaced between two runs started
  over, a server without ranges given one stream, connections cut short taken up again, a refusal
  said, only https fetched. Each time the file byte for byte.
- `Tests/BrowserCoreTests/VMGuestScriptTests.swift` (Linux and macOS): **the boot script itself,
  run from its first line to the shutdown** by `/bin/sh`, with every command it calls by its full
  path replaced by one of the test's own that writes down how it was called (a command the script
  learns to call and the test has no word for fails the test), and every place it reads or writes
  a folder of the test's. What the app writes for a profile goes in; what the script would have
  done to a machine's macOS comes out command by command: each setting's command and its order
  before Safari is opened, what an unset setting leaves alone, a Dock that is not started again
  when nothing of it changed, the picture's later looks and its marker, a failure's words in the
  status, values that are not settings reaching no command (and running as none), nobody signed
  in, no settings file, and a newer script taking this one's place. What it cannot show is what
  macOS then does with those commands.
- `Tests/VMNetCoreTests` and `scripts/vmnet_interop.sh` (Linux): the network against the real
  Linux TCP stack.
- CI compiles the helper and the app's side on macOS and starts the helper once. **No test runs a
  machine**: CI's Macs are themselves virtual machines, and a guest cannot run a guest. The first
  run of everything above the model is on a person's Mac — see the list below.

### First run on a Mac — what to look at

1. Add Virtual Machines: Apple is asked, the download shows its size, speed and time left; Pause
   and Continue go on from the same byte; quitting Lumen and opening it again goes on too.
2. The installation runs to the end and the base opens in a window; macOS's setup can be completed
   with this Mac's own connection.
3. "My Shared Files" is in the guest's Finder with Install Lumen Tools; it runs, signs in
   automatically after that, and shuts the machine down; the section then shows the machines' list.
4. A new machine with a proxy: its first start clones the base in seconds; the guest reaches the
   web only through the proxy (its address at a "what is my IP" page is the proxy's), the time zone
   and Safari's language are the proxy's country's.
5. The same machine with the proxy turned off at the provider: it is not started, and says why.
6. Shut Down closes the guest within some seconds; Lock with a machine running waits for it.
7. "What sites see" in the machine's Safari, beside a real Mac's: the first measurement of the
   paravirtual GPU's fingerprint.
8. Instant wake on for a machine: its first start is the usual one; Close puts it to sleep in
   seconds ("asleep · opens at once" in its row, a `state.vzvmsave` beside its disk); Open brings
   it back as it was — the same pages — in seconds, its clock right within a few more, and pages
   load again. Change its memory and open it: it starts anew, and the row says why. A row that
   says the machine cannot be saved names the one thing to look into first: the helper's log
   line "wake: this machine cannot be saved". Open it and close its window at once, while it is
   still black: it is put to sleep again once awake ("asleep" in the row), not shut down, and
   the next Open brings it back as it was. On its first start with a new keyboard layout the row
   says the layout waits, its button is Shut Down, and the window's close asks; after that one
   shutdown the layout is in use.
9. Browser mode on: the machine's start is covered, and the cover goes when Safari is over the
   whole screen; "Safari Full Screen (in the Machine)" in the row's menu toggles it. If the
   cover goes and Safari is in a window, the machine's view did not take the key made for it.
10. "Network…" in a running machine's menu: hosts appear as pages load, with their counts;
    Block ends a host's connections at once and the page that needs it stops loading.
