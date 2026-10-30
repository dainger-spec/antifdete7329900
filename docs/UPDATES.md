# Automatic updates

Status, 2026-10-30: **design decided, implementation follows in steps** (one topic per commit, CI
green after each). This document is the decision and the rules; each later commit says which part
it implements and how it is proven.

| Part | State |
|---|---|
| §4, the formats of the files on disk | in force (`DocumentFormat`; `FormatPolicyTests`, the self-test's `formatPolicy`) |
| §2, the signed feed and its checks | in BrowserCore (`UpdateVerifier`, `UpdateSigner`, `BuildVersion`; `UpdateTests`) and `pbupdate`; no app uses it yet |
| §3 quit and install, §5 the check, §6 release, §7 the screen | not yet |

Two facts make updates harder here than in most apps:

- **Quitting is encrypting.** A running profile's data is decrypted on disk; it is sealed when the
  profile stops, and every profile stops on quit (`QuitCoordinator`, `ProfileManager.shutDown`, a
  profile's own process quitting on `.stop` or `SIGTERM`). An update that replaced the app around
  that path would leave profiles in plaintext. Downloading and replacing files is the small part;
  the order of quitting, and what is allowed on disk across versions, is the large part.
- **Fixes have to arrive fast.** The Safari-chrome path patches Safari's private frameworks, and a
  macOS update can break that overnight (on macOS 27 the content web view was found to bypass
  Safari's factories; everything held on the WKWebView initializer hook — docs/LEAK_AUDIT.md item
  1). Updates are how such a fix reaches people in hours, not weeks.

## 1. The decision: our own updater, behind `Updater`

The two options and their costs:

- **Sparkle 2** does the tedious part — write permissions and authorization, quarantine, the code
  signature of the update, the atomic replacement, rollback. Cost: a package dependency, the
  framework and its XPC services embedded, all of it signed by our own `scripts/build-app.sh`.
- **Our own**: a signed static appcast, Ed25519 (already here: CryptoKit on macOS, swift-crypto on
  Linux), the download, the code-signature check of the downloaded bundle, the atomic replacement,
  the relaunch. Cost: every edge case of replacing a bundle is ours.

The default was Sparkle 2 unless embedding and signing it turned out disproportionate. They did not
— copying `Sparkle.framework` out of SwiftPM's artifacts, an rpath, signing `Autoupdate`,
`Updater.app` and `Installer.xpc` inside out, and two `mach-lookup` exceptions in the sandboxed
entitlements is some 30–40 lines of `build-app.sh`. **The decision is our own updater anyway**, for
reasons checked in Sparkle's own sources (branch `2.x`, release 2.10.1):

1. **Sparkle installs on any termination once an update is downloaded.**
   `SPUUpdaterDelegate.h`, `-updater:willInstallUpdateOnQuit:immediateInstallationBlock:`: "In
   either case Sparkle will always attempt to install the update when the app terminates."
   `SPUUserDriver.h`, `-showReadyToInstallAndRelaunch:`: "If the application terminates on its own,
   Sparkle will attempt to automatically install the update." An update downloaded in the
   background is already in the installing stage, so a quit in which a profile's process had to be
   killed, or a crash of the manager with profiles decrypted, installs it. The only veto is to
   reply `SPUUserUpdateChoiceSkip` while the app still runs; a crash cannot reply. Our rule is the
   opposite: **the bundle is replaced only after every profile is confirmed sealed, and anything
   else cancels the update** (§3). With Sparkle that rule holds only if nothing is downloaded
   before the quit — which gives up "download in the background, install at quit".
2. **One executable is every process.** The manager and every profile's process run the same
   binary (`--profile-session`), and a profile's process is held to its proxy by
   `ProfileNetworkGuard`. Linked in, Sparkle would be loaded into every profile's process, and its
   sandboxed setup adds an installer-launcher XPC service, outside the sandbox, that any process of
   the bundle can reach. Not a network door as long as the downloader service is left out, but
   surface the guard would have to account for — where our updater is code that only ever runs in
   the manager process, and a helper that makes no network request at all.
3. Not a reason: signed feeds. Sparkle 2.9.0 added them (`SURequireSignedFeed`, #2822 and #2828).

The mechanics stay behind our own protocol, `Updater` (check, download, state, install at quit,
install now). If Sparkle ever lets the host veto installation on termination, it can be put
behind the same protocol without touching the quit path, the settings or the screens.

What we take on, and how each case is met — refused openly rather than worked around:

| Edge case | Our answer |
|---|---|
| The app's location is not writable (a standard user, `/Applications` owned by an admin) | no install; the update screen says so and links the download page |
| App Translocation, a read-only volume (run from a disk image) | detected; no install; "move the app to Applications first" |
| Another copy, or a stray process, running from the bundle | the installer waits for it, never kills it, and gives up after 10 minutes |
| An interrupted replacement | `renamex_np(RENAME_SWAP)`: the old and the new bundle swap atomically; on any failure after the swap the installer swaps back |
| The sandboxed build cannot write its own bundle | a small helper app embedded in the bundle, launched through LaunchServices (so outside the sandbox), does the replacement and checks everything itself |
| Quarantine | the archive is fetched by our own URLSession (no quarantine flag); Gatekeeper still checks a notarized app at its first launch |
| Delta updates | not supported: every update is a whole signed zip |

## 2. Finding, fetching and checking an update

```
manager process (never a profile's)            helper app (Contents/Helpers, no network)
───────────────────────────────────            ─────────────────────────────────────────
GET appcast.json (static, ephemeral session)
verify the envelope's Ed25519 signature
newer than the last appcast accepted? (freshness)
pick the newest item: newer build, this macOS
GET the item's zip → staging folder
length, SHA-256, Ed25519 of the zip
ditto -x -k → staged bundle
code signature (strict, nested), identifier,
  Team ID policy, Info.plist versions == item's
state: "downloaded, installs at quit"
… quit: every profile sealed (§3) …
launch helper (LaunchServices) ───────────────►  wait for the app to exit, and for every
app exits normally                                process of the bundle to be gone
                                                 verify the zip's Ed25519 again (keys from the
                                                   installed app's signed Info.plist), extract it
                                                   itself, code signature, versions
                                                 RENAME_SWAP installed ⇄ new; verify in place
                                                 launch the new app; swap back if it cannot start
                                                 write the outcome for the next launch to show
```

**The appcast** is one static file: a JSON envelope `{"format": 1, "keyID": …, "payload": <base64
of the appcast JSON>, "signature": <base64 Ed25519 of those payload bytes>}`. The signature is over
the payload's bytes, checked before anything in them is read. The payload lists the releases:
`version` (CFBundleShortVersionString), `build` (CFBundleVersion: whole numbers separated by dots,
compared component by component — anything else refuses the list), `minimumSystemVersion`, `url`
(https only), `length`, `sha256`, `keyID` and `edSignature` (the key that signed the zip, and the
Ed25519 signature of the zip's bytes), `publishedAt`, and `notes` — plain text. A release that
cannot be judged (not https, not a build number, not a SHA-256) refuses the whole list. The payload
also carries `generatedAt`: the app remembers the newest it accepted and refuses an older appcast (a
mirror or a cache replaying an old, validly signed list cannot hold an update back for good, nor
serve one older than what was already seen). An envelope of a newer `format` is not judged at all.

**Keys.** Public keys are in the app's `Info.plist` (`PBUpdatePublicKeys`, `keyID → base64`), put
there by `build-app.sh` from the release environment; a key's id is the first 8 bytes of the SHA-256
of its raw public key, in hex, and an entry whose id is not its key's is ignored. Several at once
allow rotation: a new key is shipped in one release and used from the next; each release names the
key that signed its zip. The private key never enters the repository or CI. `pbupdate` (a small
tool in this package, built on macOS and Linux) makes keys, signs a release and the appcast, and
checks them — with the same BrowserCore code the app checks them with.

**Never installed:** an appcast or a zip whose signature does not check with an embedded key; a zip
whose length or hash differs from the item; a bundle that is unsigned, whose signature does not
validate (strict, nested code included), whose identifier is not ours, whose Team ID is not the one
built into this app, or whose `Info.plist` versions differ from the item's; an item not newer than
the running build (no downgrade, ever — §4); one that needs a newer macOS.

**Team ID.** A release build carries the Team ID it must find in an update (`PBUpdateTeamID`, from
`TEAM_ID` at build time), and the update must be signed with a Developer ID of that team. A build
without one — every build until there is a paid Apple account — accepts only an update whose
signature validates and whose zip's Ed25519 signature checks: then the code signature proves the
bundle is intact, not who made it, and the Ed25519 key alone proves origin. The update screen says
which of the two this build does.

**Release notes are text.** The appcast's `notes` field is shown in a `Text` view. No HTML, no web
view, no remote load: a release-notes page rendered by WebKit would be the one page in this product
loaded outside every profile, and that is exactly the kind of exception this product exists to
avoid.

## 3. Installation only through the quit path

Policy by default: **download in the background, install at quit.** No silent install with a
relaunch under running profiles, ever.

At quit (`QuitCoordinator` → `AppModel.lock(forQuit:)` → `ProfileManager.shutDown`), with an update
staged, a gate runs after sealing and before anything else happens to the update. It passes only
if all of these hold:

1. the manager reports nothing running, launching or sealing (`hasActivity` false);
2. every profile process ended through its own quit path. The quit waits 30 seconds for a profile
   process and then kills it (`ProfileProcess.waitUntilExit`; its data is re-sealed at the next
   unlock). That stays the quit's behaviour, but a profile that had to be killed fails the gate;
3. on disk, for every profile of the vault: no WebKit data in plaintext
   (`WebDataStoreVault.discoverDirectories`), no Safari home in plaintext, and no home lock held
   (`SafariHomeVault.isInUse`) — checked on the files, not taken from memory;
4. profiles started only for a warm-up (no window; nobody remembers them) are covered by the same
   checks: while they run they are sessions or processes of the manager like any other.

If any check fails, **the update is not installed**: it stays staged for the next quit, and the
next launch says which profile failed and why. A crash never installs anything: the helper is
started only by the gate.

**Update now** while profiles run: a confirmation lists everything that will be stopped — profiles
with windows, in their own processes, warm-ups without a window, launches and seals under way — and
only on confirmation does the quit path run. If the gate fails then, the app does not exit: it stays
locked, says why, and keeps the update.

The helper is the only process that touches the bundle. It is launched by LaunchServices — so it is
not in the sandbox of the sandboxed build, and not a child that ends with the app — and it trusts
nothing it is handed but paths: it waits for the app to exit and for every process running from the
bundle to be gone (no kill; it gives up after 10 minutes), verifies the update again with the keys
of the installed app's signed `Info.plist`, extracts the zip itself, swaps, verifies in place,
launches the new app, swaps back if it cannot, and leaves its outcome for the next launch.

## 4. Data on disk across versions

Rules, each with tests (`Tests/BrowserCoreTests/FormatPolicyTests.swift`; Safari's home archive also
in the self-test, which runs the app's own code for it):

- **R1 — the new reads the old.** Every format a released version wrote stays readable. The tests
  keep `vault.json` and a profile's settings exactly as released versions write them — frozen, never
  regenerated: the vault opens with its password, the settings keep their values — and check that
  this version writes the files that never had a format marker exactly as before, without one.
- **R2 — the old refuses the new, and never writes it.** A file's JSON may carry a top-level
  `format`; without one it is format 1 (`DocumentFormat`) — every file this version writes, and the
  files whose JSON is an array or a map of its own. A reader checks the format before it decodes
  anything and refuses a newer one, or one that is not a whole number, with `CoreError.newerFormat`;
  the app says so in the person's language ("The file … was saved by a newer version of
  PrivacyBrowser…"). A file that declares a newer format is never written over and never deleted:
  every writer looks before it writes, whatever its caller read or failed to read first — a save of
  defaults after a failed read included.
- **R3 — no downgrade.** The updater never installs an older build. In the vault, the `format` of
  `vault.json` is the generation of everything in it: a version that writes anything an older one
  cannot read raises it first, and every older version then refuses to unlock the vault at all — one
  clear message instead of profiles failing one by one. That includes the versions from before these
  rules: they open only format 1 (their `readHeader` refuses anything else). A sync location is the
  same: a newer `vault.json` there stops this version's sync, and the setup of a new device from it.
  The versions from before these rules do not look at the header on the sync location, only at each
  record's envelope (`pbsync-1`, anything else refused), so a version that raises the vault's format
  raises the envelope's too. (A separate data-generation field was planned first; those versions
  would have ignored it, as they ignore every key they do not know.)
- **R4 — a change an older reader would get wrong is a format change.** The settings' decoder takes
  what it knows from any JSON and defaults the rest, so a newer version's settings would be read as
  this version's and written back without what it added; the proxy list skips entries of a kind it
  does not know, and drops them when it saves. A later version that adds such a field or kind
  raises the file's format.

| File | Holds | Before these rules | Now |
|---|---|---|---|
| `vault.json` | KDF parameters, the wrapped master key, the vault id | `format` = 1, anything else refused | newer: the vault does not open, and a password change does not write over it; also the generation of the vault (R3) |
| `index.bin` | the profile list | `format` = 1, anything else refused | newer refused; not written over, by this device or by sync |
| `config.bin`, `config.bin.conflict` | a profile's settings (synced) | **no marker** — an older version drops new fields and writes the rest back | `format` read (absent = 1; this version writes none); newer: the profile does not start, nothing is written |
| `passwords.bin` | saved passwords | **no marker** (a JSON array) | the array is format 1; an object with a newer `format` is refused, and no change is written |
| `history.bin`, `bookmarks.bin` | history, bookmarks | `format` = 1, **not checked** | checked; newer refused, never written |
| `cookies.bin` | the synced cookie jar | `format` = 1, **not checked** | checked; newer refused: not merged, not emptied when cookie sync is turned off |
| `cookies-baseline.bin` | this device's last cookie state | no marker | `format` read (absent = 1); newer refused, not written over, not deleted |
| `cookies-import.bin` | cookies queued for the next launch | no marker (an array); **deleted when it could not be read** | newer refused, not written, **not deleted** |
| `warmup.bin`, `warmup-schedule.bin` | the warm-up plan, its schedule | no marker | `format` read (absent = 1); newer refused, never written |
| `proxies.bin` | the proxy list | `format` = 1, anything else refused | newer refused with the newer-version message, never written; unknown kinds of entry: R4 |
| `settings.bin` | sync target, automation API settings | no marker — a failed read falls back to defaults **that are then saved over the file** | `format` read (absent = 1); newer: said at unlock, and the defaults are never saved over it |
| `sync-state.bin` | what sync last saw | no marker (a map) | newer: the sync stops before it fetches or pushes anything (starting over would push this device's files over newer ones) |
| `webdata.pbsa`, `safarihome.pbsa` | WebKit's data, Safari's home, archived | `PBSA` + version byte 1, anything else refused — **and a refused Safari home archive left an empty home behind, which the next unlock or an export of the profile sealed over the archive** | newer refused before anything is read from it; the profile does not start; no home is left; nothing is sealed over it |
| `*.pbprofile` | a profile export | `format` = 1 in its header, anything else refused | newer: the newer-version message, nothing imported |
| sync records | on the sync server | envelope `pbsync-1`, anything else refused | the envelope as before; the file inside a record is checked like the file itself, on the remote copy and on this device's: a newer one is neither pulled, nor merged, nor written over — the sync stops |

Two of these lost a newer version's file whatever its format said, and were found while writing
the rules: the queued cookie imports, deleted when they could not be read, and the Safari home above.

The contents of the two archives are WebKit's and Safari's own files: those formats belong to macOS,
which migrates them forward itself; going back to an older macOS is outside what this app can
protect. The updater's own state (when it last checked, what is staged, the newest appcast
accepted) is not in the vault: it lives in the app's user defaults, holds nothing secret, and is
read before any vault is unlocked.

## 5. Privacy of the update check

- **One static URL**, from the app's `Info.plist` (`PBUpdateFeedURL`): a plain GET with no query
  string, no install id, no serial, no hardware or profile detail, no cookies, no cache, no
  credentials, and a User-Agent of `PrivacyBrowser` without a version. A build without a feed URL
  (every development build) has no updater and sends nothing.
- **What the server sees, honestly:** this Mac's IP address and when it checks; when an update is
  downloaded, which one — and so, roughly, which version was installed before. Nothing else.
- **Never tied to a licence check.** Whatever licensing comes later goes to another host, at
  other times, with nothing in common: tied together, the update check would bind the installed
  version, and the times the app is used, to a person.
- **Not a profile's traffic, and not a door around `ProfileNetworkGuard`.** The check is the app's
  own request, like sync's: it does not go through any profile's proxy and is not counted as any
  profile's traffic. It is kept apart by construction:
  - the updater exists in the manager process only: a profile's process (`--profile-session`)
    never creates one (a code guard, and a self-test check);
  - nothing that fetches can be asked to fetch by a profile's process: the helper takes paths,
    makes no network request, and installs only what verifies with the embedded keys — there is
    no XPC service and no listener;
  - the updater's URLSession is its own, ephemeral, and never given to web content; in the
    sandboxed build, where profiles run in the manager process, their web views keep their data
    stores' proxies, and the updater's session is not a data store.
- **The switch.** "Check for updates automatically" off means off: no timer, no request at launch,
  nothing. "Check Now" is a request the user makes by pressing it. Default on in a build that has a
  feed URL.

## 6. Signing, notarization, `scripts/release.sh`

`scripts/release.sh`: build → sign with Developer ID → notarize (`notarytool`) → staple → zip
(`ditto -c -k --keepParent`) → sign the zip with Ed25519 → the appcast item, and the signed appcast.
Every step that needs an Apple account or a key reads it from the environment (`SIGN_IDENTITY`,
`TEAM_ID`, `NOTARY_PROFILE`, the Ed25519 private key); without them the script runs dry — ad-hoc
signing, notarization and stapling skipped and said so, a throwaway Ed25519 key — so CI runs it on
every push and the release path is not untested code on the day there is an account.

## 7. Interface

An **Updates** sheet (Profiles window → ⋯ → Updates…): the version running; Check Now; "Check for
updates automatically"; what to do with an update (install at quit — the default — or only tell
me); the release notes as text; the state — up to date, checking, downloading, "downloaded,
installs when you quit", failed with the reason, not available in this build (no feed URL), or a
location the update cannot be installed to. Install Now asks first when profiles run, listing them.
In the UI snapshots.

## 8. How it is proven

- **Unit tests (BrowserCore, Linux and macOS):** the appcast envelope and its items; Ed25519 of the
  appcast and of a zip, a forged or tampered one refused; versions compared component by component;
  no downgrade; an appcast older than the last accepted refused; R1–R4 for every file in §4.
- **Self-test (macOS, real app):** the appcast and a "new" bundle (a copy of the app under test with
  a higher build, re-signed, zipped and signed with a test key) served from a local server, as the
  proxy checks use `scripts/selftest_proxy.py`:
  - no update is installed while a profile runs, without confirmation;
  - when the bundle is replaced, every profile is sealed — the warm-up profile without a window too;
  - a forged signature is refused;
  - an older build is refused;
  - with automatic checks off, not one request: the local server sees none, and the packet capture
    around it (scripts/egress_check.py) sees nothing of the app;
  - after the replacement the app starts again and opens its data;
  - Safari's home archive of a newer version is refused, leaves no home, and nothing is sealed over
    it (`formatPolicy`).

## 9. Not done

- Installing into a location that needs administrator rights (Sparkle asks for a password; we say
  "not installable here").
- Delta updates.
- Updating the packet-tunnel system extension: a new extension version is activated by
  `OSSystemExtensionRequest` at the next launch that needs it, as today (docs/TUNNEL.md).
