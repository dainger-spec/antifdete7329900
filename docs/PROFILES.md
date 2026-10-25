# Profiles, snapshots, cookies and fail-closed networking

This is the design and current state of the profile system. The logic lives in
`vm/controller-app/Sources/VMControllerCore/` (built and unit-tested on Linux
and macOS); the app and CLI drive it.

## Profiles on snapshots

A **profile is one Tart VM**, cloned from a base image, with its own persistent
disk, proxy, cookies and settings. The profile list is a JSON file
(`ProfileStore`) at `~/Library/Application Support/VMLauncher/profiles.json`,
written atomically. Each profile stores: `id`, `name`, network mode and
`proxy`, `timeZone`, `language`, `lastURL`, `baseImage`, `clipboardShared`,
`cookieCount` and cookie import/apply times, `uniqueIdentity`, its VM name,
timestamps (`Sources/VMControllerCore/Profile.swift`).

The VM name (`pb-<name>-<id>`) is **fixed when the profile is created**.
Earlier versions derived it from the current name, so renaming a profile
pointed it at a VM that didn't exist (the next launch cloned a fresh one and
the old VM, with all its data, was left behind). Old profiles are pinned on
their first save; one already cut off this way gets its VM back on the next
launch (`ProfileStore.adoptOrphanedVM`, matched by the id suffix).

### The snapshot model — and what Tart actually offers

Tart has **no `snapshot` command**. Two facts give us snapshots anyway:

1. `tart clone <src> <dst>` makes a full, independent copy of a VM.
2. A VM's disk **persists across `run`/`stop`** — stopping a VM keeps whatever
   changed on its disk.

So the lifecycle maps as (`ProfilePlan`):

| Action | Tart | Why |
|---|---|---|
| **Create profile** | `tart clone <base> pb-<name>-<id>`, then `tart set … --random-serial --random-mac` | the clone is the profile; its disk is the "snapshot". The `set` gives it its own machine identity (below) |
| **Run** | `tart run pb-<name>-<id> …` | boots from the profile's persistent disk = its last state |
| **Close** | `tart stop pb-<name>-<id>` | disk already holds the new state — the save is automatic, no command needed |
| **Delete** | `tart delete pb-<name>-<id>` + the profile's folder | removes the VM and its imported cookies — nothing of the profile stays on disk |
| **Restore point** (optional) | `tart clone pb-<name>-<id> pb-<name>-<id>--<label>` | an explicit rollback copy |

"Snapshot on close" is therefore **inherent**, not a separate step: because the
disk persists, closing the VM *is* saving the snapshot. An explicit restore
point is an extra clone (`ProfilePlan.backup`).

## Are profiles really separate?

What each profile has **of its own**:

| | How |
|---|---|
| Disk: Safari's cookies, local storage, cache, history, saved logins, everything else | its own Tart VM (a clone; copy-on-write, but writes never reach another profile) |
| Network path and IP | its network mode: its own proxy, direct, or none |
| Serial number / hardware UUID (`VZMacMachineIdentifier`) | `tart set --random-serial` right after the clone. **`tart clone` copies the base image's identifier**, so profiles created before this all have the same one (the profile page offers «Сделать уникальным»; doing it on a used profile can lock Safari out of passwords saved in its "Local Items" keychain, which is bound to the machine) |
| MAC address | `tart set --random-mac` (a clone of another *local* VM already gets one; one cloned from the OCI cache doesn't) |
| Hostname | `Mac-<id>` (vm/identity.sh, seeded with the id, not the name) |
| Time zone, language | per profile, set in the guest (sites read both) |
| Clipboard | not shared with the Mac unless enabled |

What is **the same in every profile** — a platform limit, see
[HARDWARE_IDENTITY.md](HARDWARE_IDENTITY.md): macOS and Safari version (the
base image), the paravirtualized GPU (WebGL/WebGPU strings), the fonts, and
the "virtual Mac" hardware model. Screen size follows the browser window. So
sites can't connect two profiles by stored data or IP, but a fingerprinting
script sees the same *kind* of machine in each — as it would for two people on
the same Mac model and macOS version.

Imported profiles keep their source's serial number (moving a profile keeps
its identity) and get a new MAC, so they can run next to the source.

## Network modes

| Mode | Policy | Sites see |
|---|---|---|
| **Через прокси** (`proxy`) | fail-closed, below | the proxy's IP; if the proxy is down, nothing loads |
| **Напрямую** (`direct`) | Tart's/VZ's NAT | this Mac's IP |
| **Без интернета** (`offline`) | fail-closed with nothing allowed | — |

Profiles saved before modes existed: with a proxy → `proxy`; without →
`direct` (they used to be isolated, so pages didn't load and nothing said
why).

## Fail-closed networking

**Goal: a `proxy` profile's VM reaches the internet only through its proxy;
an `offline` one — or a `proxy` one without a usable proxy — has no internet
at all.** It fails closed, never open.

> **Fixed 2026-10:** earlier versions passed only `--net-softnet-allow
> <proxy>/32` (or `127.0.0.1/32`). That does **not** restrict egress: by
> default softnet lets the VM reach every globally routable address, and
> `--allow` only opens private ranges on top of that. The guest proxy was also
> never configured, so profile traffic went **directly** to the internet from
> the host's IP. Both are fixed below.

Mechanism: Tart's **softnet** backend with a default-deny policy, plus the
proxy set as the guest's system proxy.

- **Proxy set (an IP):**
  `--net-softnet --net-softnet-block 0.0.0.0/0 --net-softnet-allow "<proxy-ip>/32,in @host"`.
  The block denies every destination; the longest prefix wins, so the proxy's
  `/32` stays reachable. Nothing else leaves the VM.
- **No proxy / unresolved hostname proxy:**
  `--net-softnet --net-softnet-block 0.0.0.0/0 --net-softnet-allow "in @host"` —
  no egress at all.
- **`in @host`:** the host may open connections *to* the VM (SSH, the agent's
  tunnel, `scp`), and their replies pass. The VM cannot open connections *to*
  the host — so it can't use the host's DNS forwarder (the gateway softnet
  hands out by DHCP) or any service listening on the host.
- **DHCP** is answered by softnet itself before any rule, so the VM still gets
  its address (`tart ip` reads it from the reservation).

`NetworkPolicy.failClosed(proxy:)` encodes this (tested): IP proxy →
`proxyOnly`, everything else → `isolated`. The controller takes
`TART_NET=softnet` + `SOFTNET_ALLOW=<cidr>` and adds the deny-all and
`in @host` itself. When the app runs the VM in its own window it starts
softnet itself with the same rules (`SoftnetCommand`: `--block 0.0.0.0/0
--allow "<proxy>/32,in @host"`).

### The guest proxy (`vm/guest-proxy.sh`)

softnet only *lets* traffic reach the proxy; macOS in the guest must also *use*
it. Right after SSH comes up the controller runs `vm/guest-proxy.sh` in the
guest with the profile's proxy (`PROXY_URL`): it sets the HTTP + HTTPS proxy
(`http://`) or the SOCKS proxy (`socks5://`, `socks5h://`, `socks4://`) on every
enabled network service, and turns PAC/WPAD and the other proxy types off.
With no proxy it turns all proxies off. The URL — credentials included — goes
to the guest over SSH stdin, never in an argv. If the step fails the launch
stops with an error (the VM could reach nothing anyway).

`https://` proxies (TLS to the proxy) are refused: the macOS system proxy
cannot speak them. Hostname proxies are not yet supported under fail-closed
(softnet's allowlist takes IPs): such a profile runs isolated.

### Requirements, checked before the VM starts

| Check | On failure |
|-------|-----------|
| `softnet` in PATH | `softnet not found …` — `brew install cirruslabs/cli/softnet` |
| softnet setuid-root or passwordless `sudo softnet` | `softnet needs root once; run in Terminal: …` (tart would otherwise ask for a password on a terminal the app doesn't have) |
| tart ≥ 2.30 (`--net-softnet-block`) | `fail-closed networking needs a newer tart …` |
| softnet ≥ 0.22 (`in @host` rules) | `fail-closed networking needs a newer softnet …` |

On old tools the controller **refuses** to start rather than run open.
`SOFTNET_FAIL_CLOSED=0` restores the old (open) softnet arguments for
development; the app never sets it.

### DNS and WebRTC leaks

- **DNS:** the VM can reach no DNS server — not a public resolver, not the
  host's forwarder — so there is no plaintext DNS leak around the proxy. With
  the system proxy set, Safari hands hostnames to the proxy (HTTP `CONNECT`,
  SOCKS5 with domain names). Anything in the guest that tries to resolve
  locally simply fails: fail-closed, not a leak.
- **WebRTC:** STUN/TURN over UDP goes nowhere unless it is the proxy, so it
  cannot reveal the host's real address. Defense in depth (planned): the agent
  can also disable WebRTC ICE in Safari per profile.

### Why this is a guarantee, not a setting in the guest

The policy is enforced on the **host**, by softnet, outside the guest. Even if
the guest proxy is misconfigured or removed, the VM still cannot send a packet
anywhere but the proxy. Bridged/NAT modes (`TART_NET=bridged|shared`) are
**not** fail-closed and are for development only.

> The rules above follow softnet's source (`lib/proxy/vm.rs`, `host.rs`) and
> are unit-tested as argv; they have **not** been run on an Apple Silicon Mac
> here. To verify on hardware, inside a profile VM without a proxy:
> `curl -m 5 https://example.com` and `curl -m 5 http://1.1.1.1` must both
> fail, `dig @$(ipconfig getoption en0 router) example.com` must time out, and
> SSH from the host must still work. With a proxy: pages load in Safari and
> `curl -m 5 https://example.com` (no proxy flag) still fails.

## Cookies per profile

`CookieImport` parses the two formats people have — Netscape `cookies.txt`
(curl/wget/extensions) and JSON arrays (EditThisCookie, Cookie-Editor) — into a
normalized `[Cookie]` and serializes the JSON the agent consumes. Stored per
profile at `…/VMLauncher/profiles/<id>/cookies.json`. Parsing, formats and
round-trip are unit-tested.

**Applying them:** on the first launch after an import, the controller POSTs
the profile's `cookies.json` to the agent's `/cookies` (pass `COOKIES_FILE=…`
to `tart-prototype.sh`) before navigating. The agent
(`vm/agent/binarycookies.py`) **merges** them into Safari's
`Cookies.binarycookies` — an imported cookie replaces the one with the same
domain/name/path, every cookie made inside the VM stays — writing a temp file
and renaming it, with Safari stopped (`pkill`, no Apple Event). Later launches
don't send them again (`Profile.needsCookieApply`), so a session Safari
refreshed is never overwritten by the old imported one. Earlier versions
rewrote the whole store on every launch, which logged the profile out of
everything it had signed into in the VM. Cookies imported without an expiry
get 30 days (the format has no "session" flag; 0 would mean 2001, i.e.
already expired). Writing the store (not `document.cookie`) preserves HttpOnly
cookies, which JS can't set.
**To verify on a Mac:** the exact sandboxed container path
(`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/`, overridable
with `$PB_SAFARI_COOKIES`) and that the sandbox permits writing it.

## Roadmap (the rest of the backlog)

Done here (core, tested on Linux/macOS CI):

- [x] Profile model + JSON store (name, proxy, lastURL, clipboard, cookies, base)
- [x] Snapshot lifecycle → exact `tart` argv (`ProfilePlan`)
- [x] Fail-closed network policy (default-deny softnet) + `TART_NET=softnet`/`SOFTNET_ALLOW` in the controller
- [x] Profile proxy set as the guest system proxy (`vm/guest-proxy.sh`, `PROXY_URL`)
- [x] Cookie import parser (Netscape + JSON) + per-profile storage
- [x] `VMController profiles list|add|remove` CLI over the store
- [x] Clipboard shared = off by default in the model

- [x] Agent applies cookies (`/cookies` + binarycookies encoder); agent
      installed once (token file) + LaunchAgent for reboot; controller reuses an
      installed agent (`FORCE_INSTALL=1` to override). Cookie-store acceptance in
      Safari is the remaining on-a-Mac check.

- [x] Onboarding + splash: a light SF Pro setup screen with an auto-advancing
      carousel of benefit cards, stage/percent progress and Cancel, shown during
      the first-launch/download wait; a first-run hint and a cached environment
      check (`SetupStatusCache`) so repeat launches don't re-probe. Logic is
      unit-tested; the visuals compile in CI and get a final look on a Mac.

- [x] Menu-bar app (`MenuBarExtra`): a quick list of profiles (click launches
      that profile — its own VM, fail-closed proxy, cookies, last URL), a
      running-VM count (parsed from `tart list`), and open-window/quit. Launches
      go through `LauncherModel.start(profile:)`. Running-count and env mapping
      are unit-tested; the menu UI compiles in CI.

- [x] Host logging: meaningful events (launch, errors, VM IP) go to
      `~/Library/Application Support/VMLauncher/launcher.log` (`FileLog`, size-
      capped), with "Открыть файл лога" in the window; crashes already surface
      as the error banner. Streamed subprocess lines stay in the in-window log.
- [x] Profile management in the window: a list with launch / edit / delete and
      "+", an editor (name, proxy, **clipboard toggle**, cookie import via an
      open panel). Cookie import writes the profile's `cookies.json`
      (`ProfileStore.importCookies`, tested). The clipboard flag is stored and
      shown; Tart macOS VMs don't share the host clipboard by default, so "off"
      is the real state — the toggle is the knob for when sharing is enabled.

- [x] Export/import a profile as one portable `.tar.gz` (manifest + cookies +
      the Tart VM directory). Import mints a fresh id and a non-clashing name
      and drops the VM under the new name — no host binding. The archive is
      treated as untrusted: only regular files (a symlinked cookies.json is
      refused), cookies re-parsed and recounted, the VM found by its
      config.json, everything rolled back on failure; the network mode and
      region travel with it. `ProfileBundle`
      uses `tar`, so it's tested end-to-end on Linux with a stub VM dir; the UI
      has Экспорт/Импорт buttons (big real VMs are the on-a-Mac check).

- [x] Resource display: a window row with running-VM count, total profile disk
      use, and free RAM — with an orange warning under 2 GB (`HostResources`:
      directory sizing + a `vm_stat` free-RAM parser, both unit-tested; the live
      `vm_stat` read is macOS-only).

- [x] Base-image update: a "Обновить образ" button pulls the latest base into
      Tart's cache (`tart pull`, with progress), and the UI explains that
      existing profiles are independent clones that don't auto-migrate
      (`BaseImagePolicy`) — recreate a profile to move it to the new base. It
      also lists any profiles pinned to a different base.

- [x] Update detection by digest: "Проверить обновление" asks the OCI registry
      for the base tag's current digest (`OCIReference` parses the ref;
      `RegistryClient` does an anonymous-token + manifest `HEAD` read — no
      download) and compares it with the digest recorded at the last pull
      (`SetupStatus.baseImageDigest`). The UI shows "Доступно обновление",
      "Актуально", or nothing when it can't tell (never pulled via the app, or
      the registry was unreachable) — `BaseImagePolicy.updateState`. A
      successful pull records the new digest so the next check has a baseline.
      Parsing, token extraction and the compare are unit-tested on Linux; the
      live registry read runs only at runtime.

Everything above is in; what's left is polish needing a Mac:
- [ ] Broader System Settings-style restyle of the main window
- [ ] On-a-Mac verification pass (the checklist items flagged throughout)

These are tracked so the UI work builds on this foundation rather than
re-deriving it.
