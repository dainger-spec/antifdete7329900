# Slimming the Safari VM

A macOS VM running Safari is the heavy part of this project. This directory
holds the levers to shrink it and a way to measure the result. The scripts run
**inside the VM** (over SSH); the sizing knobs are set **on the host** through
`tart set` / `vm/controller/tart-prototype.sh`.

## TL;DR

```bash
# One-time, inside a freshly cloned VM (over SSH), then reboot and snapshot:
scp vm/tuning/*.sh admin@<vm-ip>:
ssh admin@<vm-ip> './slim-macos.sh && ./cleanup-image.sh && sudo reboot'

# Every launch, on the host — the hard RAM cap is the biggest win:
VM_MEMORY=2048 VM_CPU=2 ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

The launcher app and CLI pass these through; `VM_MEMORY`/`VM_CPU`/`VM_HEADLESS`
are environment variables on `tart-prototype.sh`.

## The levers, by impact

1. **RAM cap — `tart set --memory <MiB>` (host).** This is the one that counts.
   Virtualization.framework hands the guest exactly this much RAM, so it bounds
   the VM's footprint directly, whatever the guest does. Start at **2048** and
   raise only if Safari gets slow or the agent times out. CPU: `--cpu 2` is
   plenty for one Safari; `--cpu 1` works but pages feel sluggish.
2. **Fewer background services — `slim-macos.sh` (guest).** Turns off Spotlight
   indexing, Time Machine, Software Update, Siri, iCloud, Notification Center,
   AirDrop/Handoff/Continuity, photo/media analysis and similar. Under the RAM
   cap this is what keeps the guest from swapping: every daemon not running is
   RAM and CPU the cap no longer has to stretch over.
3. **No host window — `VM_HEADLESS=1` (`--no-graphics`).** Saves host-side
   rendering, not guest RAM. See the caveat below.
4. **Smaller disk — `cleanup-image.sh` (guest).** Disk, not RAM. Do it once so
   snapshots and transfers are smaller.

## What stays on (do not disable)

Safari needs the GUI stack and HTTPS trust; the controller needs networking and
SSH. `slim-macos.sh` has a hard `PROTECTED` allowlist it refuses to touch:
**WindowServer / WindowManager / loginwindow** (no WindowServer, no Safari —
you cannot run Safari "headless" inside the guest), **mDNSResponder, configd,
networkd, nehelper/neagent** (networking and DNS, incl. the proxy path),
**opendirectoryd, securityd, trustd** (TLS certificate validation),
**sshd**, and the Launch Services / preferences plumbing every app uses.

## System Integrity Protection

On a stock image SIP is on, and it **refuses to disable many Apple daemons**.
`slim-macos.sh` asks for what it can, prints each as `disabled` or
`skipped (SIP or absent)`, and never fails on a refusal. The reliable wins
under SIP are Spotlight (`mdutil`), Time Machine (`tmutil`), Software Update
(`softwareupdate --schedule off`) and the RAM cap. To disable the rest, turn
SIP off once in the base image from Recovery (`csrutil disable`) — a bigger,
optional step; weigh it against the security trade-off for your use.

## Headless caveat

`VM_HEADLESS=1` adds `--no-graphics`, which drops the VM window on the host.
The guest keeps its virtual display, so Safari renders and `/screenshot` works
on current Tart. If, on your Tart build, headless removes the display and pages
or screenshots break, leave `VM_HEADLESS` unset and run with the window — the
RAM difference is on the host, and small.

## Measuring

Guest-side, over SSH:

```bash
ssh admin@<vm-ip> './measure-ram.sh'          # human-readable, MiB
ssh admin@<vm-ip> './measure-ram.sh --json'   # capture before/after
```

`used = wired + active + compressed` — occupied memory, excluding reclaimable
file cache. That is the number to drive down.

Host-side (the figure that decides how many VMs fit) — the `tart run` process's
resident size:

```bash
pid=$(pgrep -f "tart run safari-profile")
ps -o rss= -p "$pid" | awk '{printf "%.0f MiB RSS\n", $1/1024}'
```

### Before / after

Not yet measured here — this environment has no Apple Silicon Mac, and Tart
runs macOS guests only there. Fill this in on real hardware with the commands
above; the method is what the table is for.

| Config | `--memory` | slim-macos | Guest `used` (MiB) | Host RSS (MiB) | Safari loads | Agent OK |
|---|---|---|---|---|---|---|
| Stock, default alloc | image default | no | _measure_ | _measure_ | ✓ | ✓ |
| Capped only | 2048 | no | _measure_ | _measure_ | ? | ? |
| Capped + slimmed | 2048 | yes | _measure_ | _measure_ | ? | ? |

What to expect qualitatively: the cap sets the ceiling the host pays (RSS ≈ the
cap plus VM overhead); slimming is what lets the guest stay under a low cap
without swapping. If `swap_used` climbs or Safari stalls at 2048, step up to
3072. Below ~2048 Safari on a modern site tends to swap regardless of slimming.

## Verifying it still works

After slimming, from the host:

```bash
VM_MEMORY=2048 VM_CPU=2 SHOT=/tmp/shot.png \
  ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

- **Safari + network + JS**: `browserleaks.com` renders — it's all JS; the
  screenshot (`SHOT=…`) shows the page.
- **Cookies/storage**: revisit a site that sets a cookie; it persists across
  navigations in the same VM session.
- **Agent**: the run ends with `/status` showing `safari_running: true`; the
  agent answered `/navigate` and `/status` over the SSH tunnel.
- **Proxy**: set one for the VM (bridged + an upstream proxy, or Tart softnet)
  and confirm the page's reported IP is the proxy's.
- **SSH not broken**: the controller reached the VM at all — the agent was
  installed and driven over SSH.

## Files

| File | Where it runs | What it does |
|---|---|---|
| `slim-macos.sh` | guest, once | disable background services (`--revert`, `--dry-run`) |
| `cleanup-image.sh` | guest, once | reclaim disk from caches/logs/trash (`--dry-run`) |
| `measure-ram.sh` | guest | report memory in MiB (`--json`, `--watch N`) |
