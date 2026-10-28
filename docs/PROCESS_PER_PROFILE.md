# A process per profile

Status: stage 1 (design, and a minimal end-to-end mode behind a setting, off by default). The
one-process mode stays the default and keeps passing the whole self-test. Stage 2 (the rest of the
app's features in this mode) is planned at the end, not started.

## Why

WebKit decides the language a profile's pages and requests carry once per *app* process, not per
web view or data store (`docs/ISOLATION_AND_LIMITATIONS.md` §6, *Language: one per app run*):

- every WebKit process gets the language list at launch, in its XPC bootstrap message;
- all data stores share one network process, where CFNetwork writes `Accept-Language`;
- a later list never reaches that network process on macOS.

So two profiles with different languages need two app processes, each with its own WebKit
network, GPU and web content processes. A shipping competitor (BlackBird, system WebKit 625.1.29 on
macOS 26, Developer ID, no App Sandbox) does exactly this: a launcher process and one process per
running profile, launched through LaunchServices (`ppid` 1), each with its own
`com.apple.WebKit.Networking`, and the language set per process (`-AppleLanguages`, `-AppleLocale`).
This design does the same and keeps this app's security model:
- the App Sandbox build stays sandboxed;
- the hardened runtime keeps every protection (no `DYLD_INSERT_LIBRARIES`, no exceptions);
- no secret in `argv`, the environment or a file.

## Roles

**The launcher** is the app as the user starts it:
- the Profiles window, the vault (master password, unlock, Lock), the profile index and names;
- profile settings, the password manager window, sync, cookie import queue, warm-up plans;
- the packet tunnel, and the proxy location lookup;
- it holds the master key and every profile key it unwraps.

It runs no WebKit for profiles in this mode.

**A profile process** is the same app bundle, started by the launcher for one profile:
- that profile's windows, tabs and Library window;
- its WebKit (one pool, one data store, its own network process);
- its web data's decrypt and seal.

It gets that profile's key and nothing else: not the master key, not the index (names, other
profiles), not another profile's key.

| Concern | Launcher | Profile process | Over the channel |
|---|---|---|---|
| Master password, vault key, index, names | ✓ | — | the profile's own name only |
| Profile key | unwraps it | receives it once per launch | key handover (below) |
| `config.bin` (proxy, zone, generation…) | reads and writes | — | the effective configuration at start (lookup applied) |
| Proxy location lookup, remembered location, exit-IP warning | ✓ | — | its result is part of the configuration |
| `webdata.pbsa` ⇄ WebKit directories | crash recovery only | decrypt at launch, seal at stop | `prepared`, `sealed` |
| WebKit pool (time zone, fonts), data store, proxy, language and locale | — | ✓ | |
| History, bookmarks (`history.bin`, `bookmarks.bin`) | not while it runs | sole writer while it runs | stage 2: Library from the launcher |
| Passwords (`passwords.bin`) | password manager | stage 1: AutoFill off (one writer) | stage 2: requests to the launcher |
| Synced cookies, imported cookies, warm-up robot, packet tunnel | ✓ | — | stage 2 |

## Launching the profile process

Three ways were compared:

| | NSWorkspace, same bundle, `createsNewApplicationInstance` | `posix_spawn` of the app's own executable | A helper `.app` inside the bundle |
|---|---|---|---|
| App Sandbox | A normal app launch of the same bundle: its own sandbox from its own entitlements, and the **same container** (the container is per bundle id), so the vault and WebKit's directories are shared. `arguments` and `environment` of the open configuration are **ignored for a sandboxed caller** (Apple's documentation of `NSWorkspace.OpenConfiguration.arguments`). Everything therefore goes over the channel. | A sandboxed parent's child inherits its sandbox. The main executable, signed with `app-sandbox` but not `inherit`, then initializes the App Sandbox a second time and is killed. It needs a separate helper executable signed with `app-sandbox` + `inherit` only, i.e. a second binary that is not an app. | Its own bundle id, so its **own container**. It cannot see the launcher's vault or WebKit data unless both use an App Group container. That needs a Team ID-prefixed group (provisioning; impossible for the ad-hoc CI builds) or the data moves. |
| Dock and menu bar | A Dock tile per profile (badged with the profile's initials) and its own menu bar. ⌘Tab lists each. | A non-bundle process: a generic Dock tile, no `Info.plist`, menus by hand. | A Dock tile with the helper's own name and icon. |
| LaunchServices | Launched like a user launch: `ppid` 1, responsible for itself (camera/microphone prompts are the app's, as today). It survives the launcher's crash and notices it through the channel. LaunchServices returns the new `NSRunningApplication` (its PID) to the caller. | A real child (`ppid` = launcher, FD inheritance). It is invisible to LaunchServices unless it registers. | As the left column, plus nested signing and packaging. |

**Choice: NSWorkspace with `createsNewApplicationInstance`, same bundle.** It is the only one of
the three that works in the sandboxed build without a second binary or an App Group, shares the
container, and gives each profile the Dock and menu presence of an app. It is also what the
competitor does. Its one limit (no arguments from a sandboxed caller) does not matter, because
nothing secret may go through arguments anyway. The non-secret parameters (profile id, vault
location, language, locale) go over the channel too, so both builds take the same path.

**How the new instance learns its role.** `main.swift` looks for a launcher before starting the
SwiftUI app:
1. It connects to each launcher socket in the container's temporary directory and checks the
   server's code signature.
2. It says hello. The launcher answers with an assignment only if the instance's PID is one
   LaunchServices returned to it for a launch it is waiting on.
3. Without an assignment the instance starts as a launcher, as today.

## The channel and the key handover

**Transport: a Unix domain socket.**
- Location: `pb-launcher-<launcher pid>.sock` in `FileManager.default.temporaryDirectory`, i.e.
  `~/Library/Containers/<bundle id>/Data/tmp/` sandboxed and the per-user `$TMPDIR` otherwise,
  mode 0600.
- Messages are length-prefixed JSON frames (at most 4 MiB). Writes use `SO_NOSIGPIPE`.
- Stale sockets of dead launchers are removed at start. A path longer than `sun_path` (104
  bytes) is refused, not truncated.

**Why not XPC.** Two app instances can only meet over XPC through a Mach service name. A
sandboxed app may register one only under an App Group prefix (`com.apple.security.application-groups`,
Team ID-prefixed) or with a temporary exception (`mach-register.global-name`). An embedded XPC
service is per client and cannot connect two instances.

**Peer verification, both ends, before anything else.**
- The kernel's identity of the peer: `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`, the audit token
  (PID, PID version, effective uid).
- Its code: `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`, then `SecCodeCheckValidity`
  against this process's own designated requirement (`SecCodeCopyDesignatedRequirement` of
  `SecCodeCopySelf`):
  - an ad-hoc build's requirement names its exact code (`cdhash`), i.e. the same binary;
  - a Developer ID build's names its identifier and Team ID.

  A peer that cannot be checked is refused (fail closed).
- The launcher also requires:
  - the peer's PID to be one LaunchServices returned for a launch it is waiting on (a hello that
    arrives before LaunchServices answers is held, up to 15 s);
  - the same uid.

  It then keeps the full audit token: a reused PID has another PID version.
- The profile process checks the launcher the same way. Under the sandbox it cannot know the
  launcher's PID.

**The handover.**
1. Launcher → process: `assign` with:
   - a fresh 256-bit launch token (the nonce);
   - the profile's id, name and vault location;
   - whether the profile is ephemeral.
2. Process → launcher: `keyRequest` with that token.
3. The launcher answers with the key only if all of these hold:
   - the token is the one issued for this launch;
   - it is unused;
   - the request comes from the very process (audit token) the launch is bound to.

   Then the token is consumed. A second request, a request with another launch's token, or one
   from another process is refused.
4. Process → launcher: `prepared` once the web data is decrypted.
5. Launcher → process: `start` with:
   - the effective configuration: proxy, time zone and the location the lookup found;
   - WebRTC relay none (the tunnel is stage 2);
   - AutoFill off (stage 1);
   - language and locale.
6. Process → launcher: `started` once its window is open.

The key travels once, in memory, over the verified socket. It is never in `argv`, the environment
or a file. The JSON frame and its base64 text are not zeroized (as in the one-process mode, keys
live in ordinary memory).

**Threats.**

| Threat | Closed? |
|---|---|
| Another process of the same user connects to the launcher | **Closed.** Under the sandbox the socket is inside the container: other sandboxed apps cannot reach it, unsandboxed ones need the user's "App Data" consent (macOS 14+). In both builds the peer must pass the code requirement and be a PID this launcher launched and is waiting on. |
| Another process impersonates the launcher (binds a socket first, or squats the name) | **Closed.** The profile process checks the server's code requirement before it sends or believes anything; launcher sockets carry the launcher's PID and stale ones are removed. |
| A replaced or patched app binary | **Closed for the peer:** its code no longer satisfies the requirement (another cdhash; another Team ID). Not closed if the launcher itself was replaced before it started (as today). |
| Replay: a profile process asks again later, or for another profile | **Closed.** One-time launch token, bound to the launched process's audit token (PID and PID version). |
| Code injection into our processes (`DYLD_INSERT_LIBRARIES`, `task_for_pid`) | **Closed by the hardened runtime** (library validation, no `get-task-allow`, no exceptions), unchanged. |
| A compromised profile process | **Partly.** It holds its own profile's key and data only. Today one process holds every running profile's key. |
| root, the kernel, a debugger the user allows | **Not closed** (out of scope, as today). |

## Lifecycle

| Event | What happens |
|---|---|
| Launch | The launcher: checks the proxy, starts the lookup through the proxy, and launches the process. In parallel, the process decrypts the web data; the launcher waits for the lookup as today (up to 3 s, 1 s when a location is remembered). Then the launcher sends `start`. The process sets its language and locale and builds the pool (time zone, fonts), store, proxy and window. |
| Stop (launcher) | `stop` → the process closes its windows and seals (WebKit-coordinated removal, retries) → `sealed` → it exits. The launcher waits for both, up to 90 s. A process that does not answer is force-terminated and its data is sealed as after a crash. |
| Last window closed / ⌘Q in the profile process | The process seals itself (⌘Q through the same `QuitCoordinator` as the app) → `sealed` → exit. The launcher marks the profile stopped. |
| Lock, ⌘Q in the launcher | `ProfileManager.shutDown()` stops every profile process and waits for every `sealed` and exit. `QuitCoordinator` is unchanged: running profile processes count as activity. |
| The profile process dies (crash, `kill -9`) | The launcher sees the socket close without `sealed`, and the process gone. It waits for the dead instance's WebKit processes to end (they exit when their host does; 2 s grace), then seals what is left with the profile key (`activeStore: false`, as unlock-time recovery does), and tells the user. The plaintext lasts seconds instead of until the next unlock. |
| The launcher dies | Each profile process sees the socket close and seals and exits on its own (it holds its key). If it dies too, the next unlock's recovery seals it (as today). |

## Language, locale, time zone

- **Language and locale.** Before its first WebKit process, the profile process puts both into its
  own argument domain (`WebContentLanguage.decide(language, locale:)`), as the competitor's
  `-AppleLanguages`/`-AppleLocale` arguments do:
  - `AppleLanguages` = `[<language of the proxy's country>]`, e.g. `ja-JP`;
  - `AppleLocale` = that language's `<language>_<REGION>`, e.g. `ja_JP`.

  So `Accept-Language`, `navigator.language(s)`, `Intl`'s default locale and default date and
  number formatting follow the profile. "The first profile decides the language" and the
  `launch.languageFixed` warning do not apply in this mode. In the one-process mode nothing
  changes.
- **Time zone and fonts.** As today: the profile's own process pool
  (`_WKProcessPoolConfiguration.timeZoneOverride`, the font allowlist). No `TZ` in the
  environment, no injected code.

## Memory and a limit

Each profile process brings its own UI process, network process and GPU process (WebKit runs one
of each per app instance), besides the web content processes every tab needs in either mode.
Expect about 150–250 MB more per running profile than in the one-process mode (the self-test logs
a profile process's footprint where the system lets it be read). Stage 1 allows at most 12 profile
processes at once (`ProfileProcessHost.maximumProcesses`); a launch beyond that is refused with a
message. Stage 2 makes the limit a setting.

## The setting

**Settings → Run each profile in its own process** (per device, in the encrypted device settings,
off by default). It applies to launches from then on; running profiles keep their mode until
stopped.

## Stage 2 (not started)

1. **Passwords.** AutoFill in the profile process: suggestions and saves as requests to the
   launcher, so `passwords.bin` keeps one writer. "Never for this website" goes to the launcher too.
2. **Sync.** It must not replace a running profile's files: sync skips them, or asks their process
   to flush and pause.
3. **Cookies.** Imported cookies into a running profile go over the channel; queued ones are
   applied at launch in the process. Synced cookies are recorded at stop by the process and
   written by the launcher.
4. **Warm-up robot** in the profile process, with the plan sent from the launcher.
5. **Packet tunnel** (WebRTC through SOCKS5) stays in the launcher; each process gets its relay
   in `start`.
6. **Library and history.** The launcher's Library for a running profile asks its process; a
   stopped one is read directly.
7. **UI.**
   - A Dock icon per profile (its flag or color), the profile's name in its menu bar, a menu item
     back to the launcher.
   - The new profile window's size: random within the device's limits, per profile, kept across
     launches. The competitor has a switch for it, `BB_RANDOMIZE_NEW_PROFILE_WINDOW_SIZE`.
   - UI tests of both processes.
8. **QUIC/HTTP3 through the proxy.** The competitor has `BB_QUIC_FULL_TRANSPORT`. Today WebKit
   sends QUIC (WebTransport) around a data store's proxy, and WebTransport is off with a proxy.
   To evaluate:
   - whether CFNetwork uses HTTP/3 at all with a SOCKS5 data-store proxy;
   - whether Network.framework's proxy configurations (`nw_proxy_config` with a SOCKS5 server
     that relays UDP, or a MASQUE/CONNECT-UDP relay hop) can carry QUIC from a `WKWebView`.
9. **Limits.**
   - The number of profile processes as a setting.
   - A watchdog for a profile process that stops answering.
   - Crash reports per profile.
