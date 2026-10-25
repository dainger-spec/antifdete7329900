# Slimming the Safari VM

Shrink the macOS VM's RAM and disk to the minimum that still runs Safari, the
agent, the network and SSH. Two scripts run **inside the VM** (over SSH); the
RAM/CPU caps are set **on the host** with `tart set` (the controller exposes
them as env vars).

## TL;DR

```bash
# One-time, inside a freshly cloned VM, then reboot and snapshot:
scp vm/slim.sh vm/measure-ram.sh admin@<vm-ip>:
ssh admin@<vm-ip> './slim.sh --measure && sudo reboot'

# Size the VM on the host (do this once, VM stopped):
tart set safari-profile --memory 1536 --cpu 2      # 2048 if 1536 is unstable

# Every launch passes the caps through:
VM_MEMORY=1536 VM_CPU=2 ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

## The levers, by impact

1. **RAM cap — `tart set --memory <MiB>` (host).** The one that counts.
   Virtualization.framework hands the guest exactly this much, so it bounds the
   footprint directly. Target **1536**; if Safari stalls or `swap_used` climbs,
   go **2048**. `--cpu 2` is right for one Safari (1 works but is sluggish).
2. **Fewer services — `slim.sh` (guest).** Disables Spotlight, iCloud, Siri,
   Notification Center, Time Machine, Software Update, AirDrop/Continuity,
   Location, Analytics/diagnostics, photo/media analysis and more. Under the
   cap this is what keeps the guest from swapping.
3. **Less disk — `slim.sh` cleanup, `--aggressive`, `--strip-dev` (guest).**
   Caches/logs always; app languages and docs with `--aggressive`;
   `/Library/Developer` (Xcode/CLT — the biggest single item) with `--strip-dev`.
4. **No host window — `VM_HEADLESS=1` (`--no-graphics`).** Host-side only.

## `vm/slim.sh`

```
./slim.sh                # disable services + safe cleanup (caches/logs/trash)
./slim.sh --aggressive   # + strip non-system app .lproj languages and docs
./slim.sh --strip-dev    # + remove /Library/Developer (see the python3 note)
./slim.sh --measure      # print RAM before/after via measure-ram.sh
./slim.sh --dry-run      # show everything it would do, change nothing
./slim.sh --revert       # re-enable the services it disabled
```

Flags combine (`--revert --dry-run`, `--aggressive --measure`, …).

### What stays on (never touched)

`slim.sh` has a hard allowlist it refuses to disable: **WindowServer /
WindowManager / loginwindow** (Safari needs them — there is no "headless guest"
for Safari, so the GUI stack stays and `VM_HEADLESS` only drops the *host*
window), **mDNSResponder, configd, networkd, nehelper/neagent** (networking,
DNS, the proxy path), **opendirectoryd, securityd, trustd** (TLS trust — HTTPS),
**sshd**, and the Launch Services / preferences plumbing. Safari, the network,
HTTPS and SSH keep working.

### `--strip-dev` removes python3 — and the agent needs it

`/Library/Developer` is the biggest disk win, but on a stock image `python3`
comes from the Command Line Tools there, and the agent (`pbagent.py`) is
Python. `slim.sh --strip-dev` **refuses** unless a working `python3` lives
outside `/Library/Developer`, or you pass `--force` (after which the agent
won't start until you install another python3). Leave it off unless you've
provisioned a standalone Python.

### System Integrity Protection, and the sealed system volume

- SIP (on by default) **refuses to disable many Apple daemons**. `slim.sh` asks
  for what it can and prints the rest as `skipped (SIP or absent)`; it never
  fails on a refusal. The RAM cap doesn't depend on any of this.
- On modern macOS `/usr` and `/System` are a **read-only, cryptographically
  sealed volume** — you cannot delete `/usr/share/doc`, `/usr/share/man` or
  system `*.lproj` even as root. So disk cleanup only touches the writable data
  volume (`/Library/Caches`, `/Library/Developer`, `/Library/Documentation`,
  `~/Library/Caches`, `/private/var/folders`, logs, non-system app languages).
  To strip more you must disable SIP from Recovery (`csrutil disable`) — a
  bigger, optional step with a real security cost.

## Tart config

Set once, VM stopped:

```bash
tart set safari-profile --memory 1536 --cpu 2
```

- **Memory 1536 MiB**, **CPU 2**. Bump memory to 2048 if unstable.
- **Audio / extra devices:** Tart attaches only the base Virtualization.framework
  set (disk, NIC, display, keyboard/pointer) — no USB or other peripherals to
  remove. The CLI has no documented audio toggle; if *your* Tart build adds one,
  pass it through with `VM_RUN_ARGS` on the controller (e.g.
  `VM_RUN_ARGS=--no-audio`) rather than assuming it exists.
- **Display:** `VM_HEADLESS=1` adds `--no-graphics` (no host window). The guest
  keeps its virtual display so Safari renders and `/screenshot` works on current
  Tart; if a build removes the display headless and pages/screenshots break,
  leave `VM_HEADLESS` unset — the saving is host-side and small.

## Measuring

Guest RAM, over SSH (`used = wired + active + compressed`, the number to drive
down):

```bash
ssh admin@<vm-ip> './measure-ram.sh'          # at rest (no Safari)
ssh admin@<vm-ip> './measure-ram.sh --json'   # capture before/after
```

RAM with Safari open: open a page through the controller, then measure:

```bash
VM_MEMORY=1536 KEEP_VM=1 ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
ssh admin@<vm-ip> './measure-ram.sh'
```

Host RSS of the VM process (how much the host actually pays), and image size:

```bash
ps -o rss= -p "$(pgrep -f 'tart run safari-profile')" | awk '{printf "%.0f MiB RSS\n",$1/1024}'
du -sh ~/.tart/vms/safari-profile     # image on disk; run before and after slimming
```

### Before / after

Not measured here — this environment has no Apple Silicon Mac, and Tart runs
macOS guests only there. Fill in on real hardware with the commands above.

| Metric | Stock | Capped 1536 + `slim.sh` |
|---|---|---|
| Guest `used`, at rest (MiB) | _measure_ | _measure_ |
| Guest `used`, Safari open (MiB) | _measure_ | _measure_ |
| Host RSS (MiB) | _measure_ | _measure_ |
| Image on disk (GiB) | _measure_ | _measure_ (`--strip-dev` frees the most) |

Qualitatively: the cap sets the ceiling the host pays (RSS ≈ cap + overhead);
slimming is what lets the guest stay under a low cap without swapping. Expect
Safari + agent to sit comfortably at 1536 after slimming for light browsing;
heavy sites may need 2048. `--strip-dev` is the big disk win (CLT is ~1–3 GB on
the base image; much more if the image carries Xcode).

## Verifying it still works

```bash
VM_MEMORY=1536 VM_CPU=2 SHOT=/tmp/shot.png \
  ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

- **Pages load (JS + network):** `browserleaks.com` renders; the screenshot
  (`SHOT=…`) shows it. **Cookies/storage:** persist across navigations in the
  session.
- **Agent answers:** the run ends with `/status` showing `safari_running: true`
  (it drove `/navigate` and `/status` over the SSH tunnel).
- **SSH works:** the agent was installed and driven over SSH at all.
- **Proxy:** with a proxy configured for the VM, the page's reported IP is the
  proxy's.

## What `slim.sh` disables

Services (via `launchctl disable` + `bootout`, SIP permitting):

- **Spotlight:** `com.apple.metadata.mds`, `Spotlight`, `corespotlightd`,
  `parsecd`, `suggestd`, `knowledge-agent`
- **Siri:** `assistantd`, `Siri.agent`, `siriknowledged`, `siriinferenced`
- **iCloud / Apple ID:** `cloudd`, `bird`, `cloudphotod`,
  `protectedcloudstorage…`, `iCloudNotificationAgent`, `itunescloudd`
- **Notification Center:** `notificationcenterui.agent`, `usernoted`
- **Continuity / AirDrop / AirPlay:** `sharingd`, `rapportd`, `AirPlayXPCHelper`
- **Location:** `locationd`
- **Analytics / diagnostics / crash:** `analyticsd`, `osanalyticshelper`,
  `SubmitDiagInfo`, `spindump`, `ReportCrash`
- **Photo / media analysis:** `photoanalysisd`, `mediaanalysisd`
- **Time Machine:** `backupd`, `backupd-helper` (+ `tmutil disable`)
- **Software Update:** `softwareupdated`, `suhelperd` (+ `--schedule off`)
- **Misc:** `ScreenTimeAgent`, `familycircled`, `appstoreagent`, `commerce`,
  `homed`, `newsd`, `weatherd`, `UsageTrackingAgent`, `AMPArtworkAgent`,
  `AMPDeviceDiscoveryAgent`

Plus `mdutil -a -i off` (Spotlight indexing), `tmutil disable`,
`softwareupdate --schedule off`. `--revert` re-enables them.

Disk (data volume only): `~/Library/Caches`, `~/Library/Logs`, `~/.Trash`,
`/Library/Caches`, `/System/Library/Caches`, `/Library/Logs`, rotated
`/private/var/log`, `/Library/Documentation`, `/private/var/folders` C/T caches,
`/private/tmp`, `brew cleanup`; with `--aggressive` non-English app `.lproj`;
with `--strip-dev` `/Library/Developer`.

## Files

| File | Where | What |
|---|---|---|
| `slim.sh` | guest, once | disable services + reclaim disk (`--aggressive`, `--strip-dev`, `--revert`, `--dry-run`, `--measure`) |
| `measure-ram.sh` | guest | memory in MiB (`--json`, `--watch N`, `--parse-stdin`) |
