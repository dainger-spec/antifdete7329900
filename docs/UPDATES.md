# Automatic updates

Status, 2026-10-30: **design decided, implementation follows in steps** (one topic per commit, CI
green after each). This document is the decision and the rules; each later commit says which part
it implements and how it is proven.

| Part | State |
|---|---|
| §4, the formats of the files on disk | in force (`DocumentFormat`; `FormatPolicyTests`, the self-test's `formatPolicy`) |
| §2, the signed feed and its checks | in BrowserCore (`UpdateVerifier`, `UpdateSigner`, `BuildVersion`; `UpdateTests`) and `pbupdate`; no app uses it yet |
| §3, the installer helper | in every build (`Contents/Helpers/Lumen Updater.app`; `UpdateInstaller`, tested on real signed bundles by `UpdateInstallerTests`) |
| §3 the quit gate, Install Now; §5 the check; §7 the screen | in the app (`AppUpdater`, `UpdateGate`, `UpdatesView`); the gate in the self-test (`updateGate`), the sheet in the UI snapshots; only builds with a feed URL have an updater |
| §6, `scripts/release.sh` | runs dry in CI on every push (ad hoc, a throwaway key, no notarization); a real release needs the account and the key from the environment |
| the end-to-end scenarios of §8 | in CI on every push, sandboxed and unsandboxed builds (`scripts/update_check.py`, `--selftest-updates`); first passed in CI run 410 |

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
| The app's location is not writable (a standard user, `/Applications` owned by an admin) | no install; the update screen says so (told from the folder's owner, group and mode: the sandboxed process cannot ask the system for the user) |
| App Translocation, a read-only volume (run from a disk image) | detected (the path; the volume's read-only flag); no install; "move the app to Applications first" — the read-only volume is not exercised by a test |
| Another copy, or a stray process, running from the bundle | the installer waits for it, never kills it, and gives up after 10 minutes |
| An interrupted replacement | `renamex_np(RENAME_SWAP)`: the old and the new bundle swap atomically; on any failure after the swap the installer swaps back |
| The sandboxed build cannot write its own bundle | a small helper app embedded in the bundle, launched through LaunchServices (so outside the sandbox), does the replacement and checks everything itself |
| Quarantine | the archive is fetched by our own URLSession; whatever quarantine flag the new app carries, the helper takes it off once the zip's Ed25519 signature and the app's code signature check |
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
state: "downloaded, installs at quit"
… quit: every profile sealed (§3) …
request.json; launch helper (LaunchServices) ─►  the installed app's own signature, then its keys
app exits normally                                and Team ID; wait for the app to exit, and for
                                                   every process of the bundle to be gone
                                                 the release again: newer, this macOS; the zip's
                                                   length, SHA-256 and Ed25519
                                                 ditto -x -k next to the app → one app: its code
                                                   signature (strict, nested), identifier, Team ID,
                                                   Info.plist versions == the item's
                                                 RENAME_SWAP installed ⇄ new; verify in place
                                                 launch the new app; swap back if it cannot start
                                                 write the outcome for the next launch to show
```

The bundle itself — its code signature, identifier, Team ID and versions — is checked by the helper,
once the app has quit and right before the swap: an archive that passed the app's checks is still
only an archive until then, and the helper trusts nothing the app handed it but file names.

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

How the gate is built (`UpdateGate`, `AppModel.installUpdateAtQuit`): `QuitCoordinator` calls it at
the one moment it can pass — when the quit has sealed everything (or nothing ran) — and only for a
quit the user asked for: **never at a logout, restart or shutdown**, which would stop the helper
with everything else; the update then waits for the next quit. A profile process killed after its
30 seconds is counted (`ProfileProcess.forcedExits`) from the moment the quit began. The disk is
looked at for every folder in the vault's `profiles/`, so the gate works with the vault locked too.

**Update now** while profiles run: a confirmation lists everything that will be stopped — profiles
with windows, in their own processes, warm-ups without a window, launches and seals under way
(`ProfileManager.activity`) — and only on confirmation does the quit path run: every profile stopped
and sealed, the vault locked, then the gate. If the gate fails then, the app does not exit: it stays
locked, says why, and keeps the update.

The helper is the only process that touches the bundle: `Contents/Helpers/Lumen
Updater.app` (`<bundle-id>.Updater`, background only, hardened runtime, **no** sandbox
entitlement — `build-app.sh` signs it first, then the app, and fails if it carries one). It is
started by LaunchServices — so it is neither in the sandbox of the sandboxed build nor a child that
ends with the app.

**How it is told what to install.** A sandboxed app cannot give a program it opens any arguments
(LaunchServices drops them for sandboxed callers), and a helper reading inside the app's container
would meet macOS's container protection (an "access data from other apps" prompt on macOS 14 and
later, unless both are signed by the same team). So the app and the helper meet in one folder:
`~/Library/Caches/<bundle-id>.update/` in the user's real home — the one folder outside its
container the sandboxed build may write, through a temporary exception for exactly that path
(docs/ISOLATION_AND_LIMITATIONS.md §9). It holds the archive, `request.json` (the app's path, the
archive's file name, the release, when it was asked) and, afterwards, `outcome.json`. The helper
takes no arguments and makes no network request.

**What it does** (`UpdateInstaller.Installer`), trusting nothing it is handed but file names:

1. checks the installed app's own code signature, and only then reads from its `Info.plist` the
   keys and the Team ID it trusts (a changed `Info.plist` breaks that signature: nothing is
   trusted, nothing installed);
2. refuses a request for another app, or one older than 15 minutes (not from this quit);
3. waits until no process runs from the bundle — the app first of all — and **kills nothing**:
   after 10 minutes it gives up and keeps the archive for the next quit; a process of the bundle
   started after the request (the app opened again) ends the request at once, since that quit is
   over and the next one asks again;
4. checks the release again: newer than the installed build, for this macOS, the archive's
   length, SHA-256 and Ed25519 signature with a key the installed app carries;
5. extracts it with `ditto` next to the app (same volume): exactly one app, the installed app's
   identifier, the release's versions, a code signature that holds (strict, nested code, every
   architecture) with the Team ID the installed app names; removes the quarantine flag from it;
6. swaps the two bundles with one `renamex_np(RENAME_SWAP)`, checks the new one again in place,
   and starts it; if it does not check or cannot start, swaps back and starts the previous one.
   Should even swapping back fail, the previous app is kept beside it as `… (previous
   version).app`, never deleted;
7. leaves `outcome.json` (installed, rolled back, refused, gave up — and why) for the app's next
   launch. One helper at a time (a lock in the folder).

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
  Lumen…"). A file that declares a newer format is never written over and never deleted:
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
  raises the envelope's too. Generation 2 did both: `vault.json` format 2 and `pbsync-2`. (A separate data-generation field was planned first; those versions
  would have ignored it, as they ignore every key they do not know.)
- **R4 — a change an older reader would get wrong is a format change.** The settings' decoder takes
  what it knows from any JSON and defaults the rest, so a newer version's settings would be read as
  this version's and written back without what it added; the proxy list skips entries of a kind it
  does not know, and drops them when it saves. A later version that adds such a field or kind
  raises the file's format.

| File | Holds | Before these rules | Now |
|---|---|---|---|
| `vault.json` | KDF parameters, the wrapped master key, the vault id, how many times the master password was changed (`passwordRevision`, optional: absent = 0) | `format` = 1, anything else refused | newer: the vault does not open, and a password change does not write over it; also the generation of the vault (R3). Generation 2 (saved passwords with versions and deletions, sync records `pbsync-2`): raised at unlock (`raiseGenerationIfNeeded`, before anything of generation 2 is written) and on the sync location at the next sync; generation 1 still opens |
| `index.bin` | the profile list | `format` = 1, anything else refused | newer refused; not written over, by this device or by sync. Missing or unreadable: no profile folder deleted, nothing pushed (ARCHITECTURE.md, `index.bin` missing or unreadable) |
| `profiles/<id>/key.bin` | a copy of the profile's entry in the index: its wrapped key, name, creation date | did not exist | `format` = 1, a newer one is not taken in (the folder stays out of the list, kept); written at create, rename, after a sync, and at unlock for a listed profile without one |
| `config.bin`, `config.bin.conflict` | a profile's settings (synced) | **no marker** — an older version drops new fields and writes the rest back; **one that could not be read was saved over by the editor with defaults (no proxy), and pushed by sync over the server's** | `format` read (absent = 1; this version writes none); newer: the profile does not start, nothing is written. Unreadable for any other reason (damaged, missing): the profile does not start, every save is refused (`CoreError.unreadableSettings`), sync never pushes it, takes the server's copy when one opens and keeps this one beside it as `config.bin.unreadable` (docs/DESTRUCTIVE_PATHS.md, R1) |
| `passwords.bin` | saved passwords | **no marker** (a JSON array) | format 2: the logins with their versions (each with the Mac that made it, `device`, optional), and the deletions — sync merges it login by login; the array (format 1) is still read and written back as 2; 3 or newer refused, and no change is written. `passwords.bin.conflict`, which syncs before format 2 left beside it, is taken in as versions kept after a conflict and then removed (docs/SYNC_FORMAT.md) |
| `history.bin`, `bookmarks.bin` | history, bookmarks | `format` = 1, **not checked** | checked; newer refused, never written |
| `cookies.bin` | the synced cookie jar | `format` = 1, **not checked** | checked; newer refused: not merged, not emptied when cookie sync is turned off |
| `cookies-baseline.bin` | this device's last cookie state | no marker | `format` read (absent = 1); newer refused, not written over, not deleted |
| `cookies-import.bin` | cookies queued for the next launch | no marker (an array); **deleted when it could not be read** | newer refused, not written, **not deleted**; unreadable: moved aside as `cookies-import.bin.unreadable`, never deleted (docs/DESTRUCTIVE_PATHS.md) |
| `warmup.bin`, `warmup-schedule.bin` | the warm-up plan, its schedule | no marker; **an unreadable one was shown as none and written over** | `format` read (absent = 1); newer refused, never written; unreadable: said on the warm-up screen, moved aside at the next save (`.unreadable`) |
| `proxies.bin` | the proxy list | `format` = 1, anything else refused | newer refused with the newer-version message, never written; unknown kinds of entry: R4. Format 2 once it holds a proxy given by Lumen's service (`ProxyOrigin`): a version from before origins would read that proxy as the user's own and write it back without its origin (R4); a list of the user's own proxies stays format 1, written as before. Nothing in this version gives a proxy from the service, so it writes format 1 only; the version that brings the service raises the vault's generation first (R3) |
| `settings.bin` | sync target, automation API settings | no marker — a failed read falls back to defaults **that are then saved over the file** | `format` read (absent = 1); newer: said at unlock, and the defaults are never saved over it. Unreadable for any other reason: said at unlock, the defaults shown, and at the first change the file is moved aside as `settings.bin.unreadable` (then `-2`, …), never written over |
| `sync-state.bin` | what sync last saw | no marker (a map) | newer: the sync stops before it fetches or pushes anything (starting over would push this device's files over newer ones) |
| `webdata.pbsa`, `safarihome.pbsa` | WebKit's data, Safari's home, archived | `PBSA` + version byte 1, anything else refused — **and a refused Safari home archive left an empty home behind, which the next unlock or an export of the profile sealed over the archive** | newer refused before anything is read from it; the profile does not start; no home is left; nothing is sealed over it. The same for a Safari home archive that cannot be restored for any other reason (damaged, a full disk): no home is left, and a home without a single file is never sealed over an archive |
| `*.pbprofile` | a profile export | `format` = 1 in its header, anything else refused | 2 since saved passwords have versions (a version that reads 1 would import a version kept after a conflict as an ordinary login, over the other); 1 still imported; newer: the newer-version message, nothing imported |
| sync records | on the sync server | envelope `pbsync-1`, anything else refused | `pbsync-2` written since generation 2, `pbsync-1` still read, any other refused; the file inside a record is checked like the file itself, on the remote copy and on this device's: a newer one is neither pulled, nor merged, nor written over — the sync stops |

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
  credentials, and a User-Agent of `Lumen` without a version. A build without a feed URL
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
  feed URL: the first check a minute after launch, then every 6 hours.
- **The request itself** (`AppUpdater`): its own ephemeral `URLSession` — no cookies, no cache, no
  credentials — with the same two headers from every Mac (`User-Agent: Lumen`,
  `Accept-Language: en`), and the appcast refused above 1 MB. Its server trust is the system's; the
  one exception is the end-to-end scenarios' local feed, accepted by its certificate's hash only in
  their own mode (§8). The archive is downloaded by the same
  session into a temporary file and moved into the staging folder, where its length, SHA-256 and
  Ed25519 signature are checked before it counts as downloaded.

## 6. Signing, notarization, `scripts/release.sh`

`scripts/release.sh`: build → sign with Developer ID → notarize (`notarytool`) → staple → zip
(`ditto -c -k --keepParent`) → sign the zip with Ed25519 → the appcast item, and the signed appcast.
Every step that needs an Apple account or a key reads it from the environment (`SIGN_IDENTITY`,
`TEAM_ID`, `NOTARY_PROFILE`, the Ed25519 private key); without them the script runs dry — ad-hoc
signing, notarization and stapling skipped and said so, a throwaway Ed25519 key — so CI runs it on
every push and the release path is not untested code on the day there is an account.

As built: `VERSION` and `BUILD` are required; `FEED_URL` and `DOWNLOAD_URL` (https only) say where
the appcast and the zips are published — for a release (the owner, 2 November):

| | Value | So that |
|---|---|---|
| `FEED_URL` | `https://dl.lumenbrowser.io/appcast.json` | the app looks for updates there (built into it) |
| `DOWNLOAD_URL` | `https://dl.lumenbrowser.io/` (the folder) | the disk image the website offers is `https://dl.lumenbrowser.io/Lumen-<version>.dmg`, the zip the updater downloads `https://dl.lumenbrowser.io/Lumen-<version>.zip` |

Both are the defaults of a release (`SIGN_IDENTITY` given), so neither has to be set; a dry run keeps
`updates.invalid`. `UPDATE_KEY_FILE` is the private key from `pbupdate keygen`
(kept out of the repository and of CI); `UPDATE_EXTRA_PUBLIC_KEYS` adds keys the app also trusts
(rotation); `PREVIOUS_APPCAST` keeps the releases of the appcast published now; `NOTES_FILE` is the
release notes (`docs/release-notes-next.txt` gathers what the next release's are to say). The app is built by `build-app.sh` with the feed, the public keys and — with a
Developer ID — the Team ID updates must be signed by (and a secure timestamp, which notarization
needs). At the end the appcast and the zip are checked with `pbupdate verify`, the code the app
itself checks them with, and the script lists what a real release still needs when it ran dry.

### What is published, and where (the owner, 1 November)

Everything is at **`https://dl.lumenbrowser.io/`**, a Cloudflare R2 bucket under its own name: the
appcast (`appcast.json`), the zip the updater downloads (`Lumen-<version>.zip`, unchanged) and the
**disk image the website offers** (`Lumen-<version>.dmg`). Made and checked by the owner on
2 November: the bucket is `lumen-downloads`, the domain `dl.lumenbrowser.io` with TLS 1.2 at least,
publishing through R2's S3 API with a key that may only read and write the objects of this bucket
(Object Read & Write); an upload and its download over the domain were tried live. A real release (`SIGN_IDENTITY` given)
takes these addresses unless `FEED_URL` / `DOWNLOAD_URL` say otherwise; a dry run keeps
`updates.invalid`, so that no build CI makes looks anywhere real.

**Why a disk image.** From a zip people leave the app in Downloads; macOS runs an app from there
translocated — from a read-only copy elsewhere — and an update cannot replace it. The image holds
the app and a link to Applications (`scripts/make_dmg.sh`): drag the one onto the other. In two
steps (the owner, 2 November): first the plain image — Finder's own window, the two icons in it —
with the whole release path brought to its end on it, the check on a clean Mac included; then, as a
change of its own on top, the window laid out: the app's dark backdrop with its mark and name, an
arrow from Lumen to Applications, the window's size and the icons' places (the picture drawn by
`Lumen --render-dmg-background`, one for both languages). The layout lives in the image's
`.DS_Store`, which only Finder writes, so the script asks Finder over AppleScript; on the release's
Mac macOS asks once **"“Terminal” wants access to control “Finder”. Allowing control will provide
access to documents and data in “Finder”, and to perform actions within that app."** — Allow (the
name is the terminal's the release runs in; System Settings › Privacy & Security › Automation turns
it on again). **Whatever goes wrong there, the image is made plain and the release goes on**, with a
warning.

**Whether the window shows its picture is checked, not said** (the owner, 3 November: 0.1.1's window
had its icons and its size and no picture, while make_dmg.sh printed "laid out by Finder" — a line
that only knew a `.DS_Store` was there). make_dmg.sh now says what the image holds, read back: Finder's
answer when asked for the window's picture right after setting it ("finder: …"), what the volume's
`.DS_Store` names — the picture's alias, its file, the path inside the volume and where the volume was
mounted when Finder made it — and the icons' places, before the image is made read-only and in the
read-only image, and whether the `.DS_Store` came through byte for byte (`scripts/dmg_facts.py`).
Then release.sh (step 3c) opens the finished image in Finder, captures its window in this Mac's
appearance and compares it point by point with the picture the image carries
(`scripts/dmg_window_shot.sh`, `scripts/dmg_background_check.py`): the backdrop, and the plates, mark
and name a window of any one colour cannot show. The block at the end says **"the image's window
shows its picture"** or **"DOES NOT SHOW ITS PICTURE"**; it never stops a release, and it is never
left out silently (`DMG_WINDOW_CHECK=0` leaves it out and the block says so). The terminal must be
allowed once to record the screen (Privacy & Security › Screen & System Audio Recording); without
it the capture holds no window and the verdict says so. CI runs the same check on the dry run's
image in both appearances, and its control — the same app laid out without its picture
(`make_dmg.sh --no-picture`) — must fail it (the `dmg-window` artifact); on macOS 27 it is reported.
After a release, the Download check workflow runs it on the published image on clean macOS 26 and 27.

What 0.1.1's image holds (the Download check on the published image, clean macOS 26.6.2 and 27.0.1,
3 November): the picture is there (`.background/background.tiff`, both pages), the `.DS_Store` is
there and came through the read-only conversion, with the window's size and the icons' places — but
its icon view is Finder's own: 48-point icons, 12-point names, no picture named. The window opened
white with small icons on both. So the picture was neither lost nor unreadable: Finder, on the owner's
Mac, did not keep the view options it was given. CI's macOS 27 (1x) kept them all with the same script,
in three variants measured in run 672 — the picture set last, set before the icons' places as 0.1.1's
script did, and a PNG instead of the two-scale TIFF — and showed the picture in each. On macOS 27
`hdiutil attach` warns that it is deprecated in favour of `diskutil image attach` and works, and
Finder's own answer for a window's picture fails (-10000) even when the picture is set and kept.

So make_dmg.sh now reads what Finder kept before the image is made read-only, and when the icons are
not of 128 points or no picture is named it asks Finder again, three times at most; then the image is
made plain, said as such (the picture is set last too, after the forum thread 836253, harmlessly).
Whether that settles the owner's Mac is for its next release to say: its block reads the window.

**The image is signed, notarized and stapled too**, after the app inside it was: `codesign` with
the Developer ID and a timestamp, `notarytool submit … --wait`, `stapler staple`, `stapler validate`
and `spctl --assess --type open --context context:primary-signature` on the image. The app keeps
its own ticket inside (`make_dmg.sh` checks that the copy in the image is the same signature and
still stapled), so it opens offline once copied out.

**Uploaded** when R2's keys are in the environment of the run — `R2_ENDPOINT`
(`https://<account>.r2.cloudflarestorage.com`, without the bucket), `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`; `R2_BUCKET` is `lumen-downloads` unless given — by `scripts/r2_publish.sh`,
with curl's own S3 signing (nothing installed):

- **Before anything is built**, the release's two names are checked free in the bucket (which
  also tries the keys), and the appcast published now is fetched from it, so that the new appcast
  keeps its releases (`PREVIOUS_APPCAST` still names another). A VERSION already published stops
  the release there, not after notarization.
- **At the end**, the zip and the image first, the appcast last — a feed never names a file not
  there yet. Each upload signs the file's SHA-256 (`x-amz-content-sha256`), so R2 itself refuses
  bytes that did not arrive as built; the object keeps it (`x-amz-meta-sha256`). The versioned
  files are cached for a year, the appcast never.
- **Each file is then downloaded from its public address** — `dl.lumenbrowser.io`, through
  Cloudflare, as anyone gets it — and its SHA-256 compared with the built file's. What is served
  must be, byte for byte, what was built; otherwise the release has failed, and the script says
  what was served instead (its SHA-256, its size, and Cloudflare's cache status).
- **A published version is never replaced.** If `Lumen-<version>.zip` or `.dmg` is in the bucket
  already, the release stops: people downloaded those bytes, the website names their SHA-256, and
  Cloudflare keeps them for a year. Only the appcast is rewritten (`--replace`). The same bytes are
  left as they are and only read back, so a publication that failed half way is finished by
  running `scripts/r2_publish.sh` again on the files in `build/release`, in the same order.
- **The keys reach curl on its standard input**, as its configuration, never on its command line,
  which `ps` shows every user of the Mac. They are in no file the script writes.

Without the keys the script says what goes where, in that order.

**No secret of a release in the repository**, which is public: `scripts/check_secrets.py` runs before
anything else and stops the release on any finding. It looks for the values of `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY` and the update key (the file `UPDATE_KEY_FILE` names) as this run has them,
and for anything shaped like R2's keys whatever its value (one of R2's variables or an `aws_*_key`
setting given 32 to 64 hex digits, an `ID:SECRET` pair of R2's shape) — in every file of every
commit any ref reaches, in the index, and in what `git add -A` would take next (files `.gitignore`
does not exclude); a file it excludes is where such keys may live. A finding names the commit, the
file and the line, never the value; a key that was pushed is public, so it is rotated first. The
whole history (all branches, 1.5 GB of files) takes about 15 seconds.

**For the website**, at the end, in one piece to copy (and in `download.json`): the image's
address, the version, its size in megabytes (decimal, as Finder counts) and in bytes, its SHA-256,
the minimum macOS. Written by a JSON serializer (`scripts/download_json.py`) and read back as the
site reads it — strict JSON, every field of the format and no other, the size and SHA-256 the
image's, the minimum macOS the app's `LSMinimumSystemVersion` — before anything is published; any
of it wrong stops the release. 0.1.1's, put together by awk and a template, said `"sizeMB": 17,5`
on the owner's Mac, whose Russian locale writes a decimal comma: no JSON reader takes that, and CI,
whose locale is English, could not have shown it. `scripts/test_download_json.sh` (CI, both jobs)
writes the file under four locales and must have each taken, and holds the check to ten files it
must refuse, 0.1.1's among them.

**Checked as downloaded**: `scripts/download_check.sh` fetches the image, marks it as a browser
marks a download, and asks Gatekeeper what macOS asks when it is opened — the image (`spctl
--type open`), its ticket, then the app copied out and marked the same way (`spctl --type
execute`, `syspolicy_check distribution`). With `--shots` it then does what the person does —
double-clicks the image, opens the app from Applications — and keeps the screen after each, with
what Gatekeeper logged; nobody answers the dialogs, so the screen shows what the person would be
asked. CI runs it on every push on the dry run's image with `--expect rejected`: an image that is
not notarized must be refused, or the check (or the runner's Gatekeeper) proves nothing; its
screens are the `download-check-control` artifact. After a release, the workflow "Download check"
runs it on the published image with `--expect accepted`, on runners that have never seen Lumen,
and keeps their screens.

**Not yet done once for real**: nothing of signing with a Developer ID, notarizing or stapling
has run with a live Apple account — CI has none, and every run so far was dry. The first real
runs are expected to need a second try: `xcrun notarytool log <submission id> --keychain-profile
lumen-notary` says why Apple refused one.

### What the owner provides for a real release (the owner, 2 November)

**`NE=1` (3 November):** its first signed, notarized build was killed by the kernel at its start on
macOS 27.0.1 — the app's executable held the network guard's provider right beside library validation
off, and the kernel kills an executable holding that right beside any relaxation of that class
(measured: docs/TUNNEL.md, "What the kernel kills"). Since then the app's own executable keeps library
validation on, and only LumenProfile has it off; build-app.sh refuses a build that pairs them again,
and release.sh stops any signed build the kernel does not start, before it is notarized. `NE=1` is
released once a build of this layout has passed release.sh and the hardware checklist
(docs/TUNNEL.md).

With the network guard (`NE=1`: WebRTC in a proxied profile through its proxy, docs/TUNNEL.md) —
since the keychain a profile's process could share with the app's is closed (docs/IDENTITY.md, "The
keychain") — the App IDs and provisioning profiles of docs/IDENTITY.md, "What to register with
Apple" (registered on 31 October; `scripts/signing_check.py --profiles-only` reads them back), and
beside them, on the Mac that runs `release.sh`:

1. **The Developer ID Application certificate, with its private key, in the login keychain.**
   Made by the team's Account Holder: Xcode › Settings › Accounts › the team › Manage
   Certificates… › + › *Developer ID Application* (Xcode makes the key and the request); or on
   developer.apple.com › Account › Certificates, Identifiers & Profiles › Certificates › + ›
   *Developer ID Application*, with a request from Keychain Access › Certificate Assistant ›
   Request a Certificate From a Certificate Authority (saved to disk), the downloaded `.cer`
   double-clicked. Then `security find-identity -v -p codesigning` lists
   `Developer ID Application: <name> (<TEAM_ID>)` — that text is `SIGN_IDENTITY`.
2. **The Team ID**: developer.apple.com › Account › Membership details › Team ID (ten characters)
   — `TEAM_ID`.
3. **The notary's credentials, stored once in the login keychain** under the name `lumen-notary`
   (`NOTARY_PROFILE=lumen-notary`), either way:
   - an app-specific password: account.apple.com › Sign-In and Security › App-Specific Passwords ›
     + (shown once), then
     `xcrun notarytool store-credentials lumen-notary --apple-id <the Apple Account's email> --team-id <TEAM_ID>`
     and the password when asked;
   - or an App Store Connect API key: appstoreconnect.apple.com › Users and Access › Integrations ›
     App Store Connect API › Team Keys › + (role Developer), the `.p8` downloaded (once), then
     `xcrun notarytool store-credentials lumen-notary --key <path to AuthKey_….p8> --key-id <Key ID> --issuer <Issuer ID>`.
   Nothing of it goes into a file of the repository; `notarytool` reads it from the keychain.
4. **The update key**: `pbupdate keygen <file>` once, the file kept outside the repository
   (owner-only, and a copy offline) — `UPDATE_KEY_FILE`. Its public half is built into every
   release; losing it means the next key can only come in an update signed with this one.
5. **The keys of the documents of rights**, as the account server prints them (`lumen-api pubkey`)
   — `ENTITLEMENT_PUBLIC_KEYS`; never the development key, which the release refuses.
6. **R2's keys** for `dl.lumenbrowser.io` — `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`,
   `R2_SECRET_ACCESS_KEY` (the bucket, `lumen-downloads`, is the default `R2_BUCKET`) — in the
   environment of the run only: typed or read from a password manager into the shell that runs
   the release, never into a file of the repository. The release refuses to start if one is in a
   commit.
7. **Xcode 27**, the active one (`xcode-select -p`): its SwiftPM declares SDK 14.0, and a release of
   a build declaring 15 or newer is refused (the certificate fetched outside a profile's proxy on
   macOS 27, docs/ISOLATION_AND_LIMITATIONS.md §2).

Then:

```sh
NE=1 APP_PROFILE=<path>/lumen.provisionprofile EXTENSION_PROFILE=<path>/lumen-guard.provisionprofile \
  TEAM_ID=<TEAM_ID> SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)" NOTARY_PROFILE=lumen-notary \
  UPDATE_KEY_FILE=<file> ENTITLEMENT_PUBLIC_KEYS=<id>=<base64> \
  R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… \
  VERSION=0.1.0 BUILD=1 scripts/release.sh
```

Before the first one, `scripts/signing_check.py` (the same variables but the R2 keys and the update
key) makes the whole chain once on a throwaway build — sign, notarize, staple, Gatekeeper, the
release check with its keychain between profiles — and writes a report with no secret in it.
Without `NE=1` the release has no guard: `release.sh` says so at the end, and a proxied profile
keeps WebRTC off.

At the end it prints the block for the website; then Actions › Download check › Run workflow with
its `url` checks the published image on clean Macs.

### Which build is released

**The build without the App Sandbox** (`SANDBOX=0`). `release.sh` refuses `SANDBOX=1` before it
builds anything, and refuses an app that, signed as it ships, does not host Safari's chrome on the
Mac it is made on (the gate, below).

**Why not the sandboxed build.** In the App Sandbox Safari's private frameworks cannot be loaded
(`SafariChrome.load`), so no profile's window is Safari's, and the app keeps every profile in its
one process (`ProfileProcess.isEnabled`) — the process that also holds the vault's master key,
where a profile's own process holds only its profile's key and its own locks
(ISOLATION_AND_LIMITATIONS.md §4a). To a site that build is plain WebKit: not what Lumen is. Before
this, it was `release.sh`'s default.

**Nothing requires the sandbox.** Developer ID distribution with notarization requires the hardened
runtime, not the App Sandbox. Only the Mac App Store requires the sandbox — and it does not take an
app that loads Safari's private frameworks at all, sandboxed or not: were the App Store ever the
channel, it is the product's promise that would change, not the build. The updater does not need
it (its helper runs outside the sandbox by design; §8's end-to-end run covers both builds). The
network guard's system extension is sandboxed by its own entitlements; the app that installs it
need not be (`build-app.sh` adds the extension's entitlements to either build; untried with a real
team, docs/TUNNEL.md).

**Which macOS.** 26 and later: `LSMinimumSystemVersion` 26.0 in the app, its updater's helper and the
network guard (build-app.sh stops if they differ), what download.json and the appcast tell people,
what the website says and what CI tests (macOS 26 and 27). The website's promise lives on its
download page in each language, /ru/download and /en/download (the owner, 3 November): release.sh reads
both before publishing (`scripts/site_minimum_check.py`), each must state the app's major version on
its own, and the check names every address it asked and what it found there — the claim's words, no
claim (with what the page says near "macOS", and whether its words are drawn by JavaScript, which the
check does not run), or the address not read, with its answer; when the site redirects, the page it led
to is named as the one read. A page that states another version, or
none, or cannot be read stops a release that publishes; a run that publishes nothing says so in its
block. (CI run 669 had read the root and the address without a language: the root need not carry the
claim, and the other answered 404, which the site fixes on its side.) A
profile's window is Safari 26's own; on an older macOS, macOS itself refuses to open the app, with
its own message — 0.1.1 said 14.0, and on macOS 15 it would have installed and not worked. The
executables still declare macOS 14 (`Package.swift`), for a measured reason: with Xcode 27, SwiftPM
writes the deployment target as the declared SDK too — `.macOS(.v14)` gives minos 14.0 and SDK 14.0,
`.macOS("26.0")` gives minos 26.0 and SDK 26.0 (CI run 667, macOS 27) — and a declared SDK of 15 or
newer turns on WebKit's network loader, with which macOS 27 fetched a certificate's intermediate
outside a profile's proxy (docs/ISOLATION_AND_LIMITATIONS.md §2; release.sh refuses such a build).
`LSMinimumSystemVersion` decides what macOS opens; the declared SDK, what WebKit does.

**Signing.** The same Developer ID Application certificate, hardened runtime and secure timestamp.
The entitlements are `Resources/PrivacyBrowser-NoSandbox.entitlements`: camera and microphone. The
profile's executable, `Contents/MacOS/LumenProfile`, is signed with them and
`com.apple.security.cs.disable-library-validation` besides — Safari's frameworks are Apple's code
loaded into a process this team signed, which library validation refuses otherwise, and they load only
in LumenProfile's processes. The app's own executable keeps library validation on: beside the network
guard's right the kernel kills an executable with it off at its start (docs/TUNNEL.md, "What the
kernel kills"). The sandbox's own entitlements (`network.*`, `files.*`, the temporary exception for
the update's staging folder) and `container-migration.plist` are not in it. `release.sh` reads the
signatures back and stops on the sandbox, on library validation off in the app's own executable or on
in LumenProfile, on a relaxation beside the network extension's right in any executable, on
`get-task-allow`, or without the hardened runtime.

**Notarization.** Unchanged: `notarytool submit`, `stapler staple`, `spctl --assess`. The notary
service requires the hardened runtime and accepts its documented exceptions, library validation
among them; it does not look for private interfaces (that is App Store review).

**The system's trust.**
- Gatekeeper: the same — a Developer ID app, notarized and stapled.
- The app runs with the user's rights rather than a container's; TCC still asks for what it
  protects. New with this build: the first download into `~/Downloads` asks (the sandboxed build had
  an entitlement for that folder), as do Desktop and Documents; camera, microphone and the local
  network asked in either build.
- The vault is in `~/Library/Application Support/PrivacyBrowser` rather than the container,
  encrypted the same. While a profile runs, its WebKit data is plaintext under
  `~/Library/WebKit/<bundle ID>/`: sandboxed apps cannot read it (their own sandbox), programs of
  this user that are not sandboxed can — in the container, macOS 14 and later asked the user first.
  Malware running as the user was never in scope (ISOLATION_AND_LIMITATIONS.md §10).
- The manager's process — the vault, the master key — is not confined by the App Sandbox, and holds
  no web content: every profile runs in a process of its own, with its profile's key only and a
  kernel sandbox profile of its own (UDP with a proxy, the real Safari's places, Safari's XPC
  services; §4a).
- With library validation off — LumenProfile's processes only; the manager's process, which holds the
  vault and the master key, keeps it on — a profile's process would load a library that is neither
  Apple's nor this team's if asked to: it loads only from `/System/Library/PrivateFrameworks`, on the
  sealed system volume, and `DYLD_*` variables stay refused (no `allow-dyld-environment-variables`).
- The local automation API exists in this build only (off by default; ISOLATION_AND_LIMITATIONS.md
  §10).

There has been no release yet. A tester's sandboxed build of the same bundle ID: the build without
the sandbox takes over its vault at its first start (README).

**The gate** (`release.sh` step 2b, on the app after notarization and stapling, run from a copy so
that what is published is exactly what was checked): `LumenProfile --check-safari-chrome` — every class and
method the chrome, and a profile's hold on its proxy, rely on is in this Safari — and
`Lumen --release-check` (`ReleaseCheck.swift`): a profile started the way the app starts one, with
nothing set by hand (`PB_PROFILE_PROCESS`, `PB_SAFARI_CHROME` or the `PBProfileProcess` default set
fail it), held to a proxy that goes nowhere, in a vault of its own in a temporary folder, must get a
process of its own whose window is Safari's own chrome; then a second profile beside it, for the
keychain between profiles (docs/IDENTITY.md, "The keychain"). Anything else stops the release:
`release.sh` takes the verdict from the check's exit status and every one of its lines
(`scripts/release_check_gate.sh`) — one PASS among them is not a pass, and a keychain FAIL after the
window's PASS stops it as any other. CI runs the gate in the release dry run on every push, and its
controls, each of which must fail for its own reason: the sandboxed build, the release with Safari's
chrome turned off for the profile's process (`--release-check --control`), the release's app with
LumenProfile signed with the app group, `release.sh` given `SANDBOX=1`, and the gate's reading held
to outputs made up for the purpose, each with the verdict it must give. What it proves is the Mac the
release is made on; on another macOS a profile whose window cannot be Safari's says so in its window
(simplified mode, ISOLATION_AND_LIMITATIONS.md §4a).

## 7. Interface

The **Updates** section of the app's Settings window (⌘, or Profiles window → ⋯ → Settings…;
`UpdatesPane` in `SettingsView`; it was a sheet of its own before the settings had one window): the version running; Check
Now; "Check for updates automatically"; what to do with an update (download it and install at quit
— the default — or only tell me, then Download); the release notes as text; the state — not checked
yet, up to date (when), checking, downloading, "downloaded and checked, installs when you quit",
failed with the reason, not available in this build (no feed URL), or a place the update cannot be
installed to (App Translocation; a folder this user cannot write). Install Now asks first, listing
what it will stop. What the server sees is said under the settings. After an update the sheet says
which one this launch is; an update that was not installed — refused, rolled back, given up, or not
handed over at the last quit — is said once at the next launch. In the UI snapshots
(`settings-updates-ready`, `settings-updates-up-to-date`, `settings-updates-unavailable`).

## 8. How it is proven

- **Publishing (CI, Linux, every push):** `scripts/test_r2_publish.sh` runs `scripts/r2_publish.sh`
  against a local R2 (`scripts/r2_local.py`) that computes every request's AWS signature again with
  the secret and refuses one that does not match, and refuses an upload whose body is not the
  SHA-256 it signed, as R2 does. Made to work: a name checked free, the image uploaded with its
  SHA-256 signed, its type and a year's cache, read back the same; the same bytes not uploaded
  twice; the appcast replaced, and fetched back as the latest. Made to fail: other bytes under a
  published name, a public address serving other bytes (one byte changed), an address that is not
  the bucket's, a wrong secret, another bucket, an endpoint with the bucket in it, an http address,
  a key with a quote in it. And curl, run through a wrapper that keeps its arguments, never had a
  key among them; nothing printed holds the secret.
- **The secret check (CI, Linux, every push):** `scripts/check_secrets.py --self-check` plants the
  secrets — in a commit a later one deletes, on a branch not checked out, in the index, in an
  untracked file, in a changed tracked one, in an ignored one — beside look-alikes, and fails unless
  every planted one is found, the ignored one and the look-alikes are not, and no value is printed;
  then the check runs on the repository itself (shapes only: CI has no key).
- **Unit tests (BrowserCore, Linux and macOS):** the appcast envelope and its items; Ed25519 of the
  appcast and of a zip, a forged or tampered one refused; versions compared component by component;
  no downgrade; an appcast older than the last accepted refused; R1–R4 for every file in §4
  (`UpdateTests`, `FormatPolicyTests`).
- **The installer on real bundles (macOS):** `UpdateInstallerTests` — apps signed ad hoc, zipped,
  their zips signed; the swap, the swap back, waiting without killing, every refusal.
- **Self-test (macOS, real app):** the quit gate on the real layout (`updateGate`); Safari's home
  archive of a newer version refused, no home left, nothing sealed over it (`formatPolicy`).
- **End to end (CI, sandboxed and unsandboxed builds):** `scripts/update_check.py` makes an
  Ed25519 key, the old build (0.1.0, build 1) and a new one (0.1.1, build 2) under their own
  bundle id, the new one zipped and signed, appcasts, and a local HTTPS feed for them — as the proxy
  checks use `scripts/selftest_proxy.py` — then runs the old build's `--selftest-updates run`
  (`UpdateSelfTest`) with its own updater, under a packet capture with each packet's process:
  - with automatic checks off, not one request: the feed counts none in 8 seconds in which one
    would have been due, and the capture holds not one packet of the app; its control — the app's
    packets to the feed once checks are on — is in the capture;
  - an older build is never offered (a feed of build 1 and 0.9 to build 1);
  - a stale appcast (validly signed, older than one accepted), a forged one (its list changed
    under the signature) and a changed archive (one byte) are refused, nothing kept;
  - the release is downloaded and checked; with a profile running in a window and another warming
    up without one — in the unsandboxed build, each in its own process — the gate does not pass
    and nothing is handed over: no request written, no installer running;
  - the quit path stops and seals both; the gate passes, no process had to be killed, and the real
    installer is started; the script sees the swap and, at that moment, looks for profile data in
    plaintext where it can see from outside the app — and says what it could not see: macOS may keep a
    sandboxed app's container from other programs, and there the app's own gate, which ran inside
    it, is the check — then sees the new build started by the installer and the installer's
    "installed";
  - the new build's `--selftest-updates verify` opens the old build's vault, profiles, settings and
    bookmarks, starts a profile from the website data the old build sealed, and seals it again;
  - every request the feed got carries the same headers from any Mac — `User-Agent:
    Lumen`, `Accept-Language: en`, no cookie, no credentials, no query string.
  The feed's certificate is self-signed, and a runner's trust settings cannot be changed without
  someone at the screen (CI run 407: `security authorizationdb write` refused, -60005). So the
  scenario mode — and only it: a build of the check's own bundle id (`….PBUpdateCheck`),
  `PB_SELFTEST_UPDATES=1`, its own command line — names that one certificate to the updater by the
  SHA-256 of its DER (`UpdateTestTrust`), and a server presenting exactly it is accepted. Nothing in
  the app sets it; for every other server, and in every other run, the system's evaluation is all
  there is.

## 9. Not done

- Installing into a location that needs administrator rights (Sparkle asks for a password; we say
  "not installable here").
- Delta updates.
- Updating the network guard's system extension: the updated app asks macOS to activate its own
  version at its next start, which replaces the old one without a new approval (docs/TUNNEL.md).
