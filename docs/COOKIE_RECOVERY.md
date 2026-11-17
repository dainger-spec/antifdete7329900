# Cookie recovery

WebKit's cookie store can lose cookies: a crash or a forced quit before CFNetwork wrote them, a
cookie file that was damaged, website data that went missing. For the people who use Lumen — who
warm up accounts and keep them signed in — a profile's cookies are its accounts. Cookie recovery is
the safety net: Lumen keeps the last snapshots of each profile's persistent cookies, inside the
profile's encrypted data, and a launch that finds the store has lost them puts them back before its
first page loads, and says so.

Code: `CookieRecovery`, `CookieSnapshot`, `CookieSnapshots`, `BinaryCookiesFile` (BrowserCore,
`Sources/BrowserCore/Cookies/CookieRecovery.swift`; the decisions, unit-tested on Linux and macOS),
`CookieSnapshotFiles.swift` (where they are kept), `CookieSnapshotKeeper` (the app: the store and the
disk, in the process that runs the profile), `CookieRecoveryNotice` (the notice in the profile's
window), `CookieSnapshotsView` (the restore by hand), `ProfileManager.prepareCookies` and `stop`.

## What is kept, and where

| | |
|---|---|
| File | `profiles/<uuid>/cookie-snapshots.bin`: `AES-GCM(HKDF(profileKey, "cookie-snapshots"), CookieSnapshots JSON)`, AAD `cookie-snapshots:v1:<uuid>` |
| What | The last **3** snapshots (`CookieSnapshots.kept`), oldest first. Each: an id, when it was taken, what took it (`periodic`, `close`, `change`), and the profile's **persistent** cookies that had not expired then — never a session cookie, never a partitioned one (as `CookieStoreSync` reads the store for sync) — one per name, domain and path |
| Written | Whole, through a temporary file and `rename(2)` (`SecureFile.write`, mode 0600): a crash leaves the old copy or the new one, never half of one |
| Key | The profile's own key, which only the manager and that profile's own process hold (`ProfileGrant`). Another profile's process can read the file's bytes, as it can every file of the vault, and open none of them: the key and the AAD are this profile's. Never plaintext on disk; plaintext only in the memory of the process that runs the profile |
| Mark | `profiles/<uuid>/cookies-running`: an empty file, there from a launch (once its cookies are prepared) to its clean stop. Found at a launch, the run before did not stop cleanly |
| Not | Synced (this Mac only), in a profile export (`.pbprofile`: the profile on another Mac starts its own), kept for an ephemeral profile (no snapshot, no mark), kept with the setting off (removed when it is turned off) |
| Restore points | `cookie-snapshots.bin` and `cookies-running` are copied into a restore point with the website data they go with, and come back with it (`ProfileRepository.restorePointFiles`): a point put back does not take its own cookies for a loss, nor bring back the cookies of the state it replaced |
| Unreadable | Not read (no restore at that launch); moved aside as `cookie-snapshots.bin.unreadable` at the next snapshot, never deleted or written over (docs/DESTRUCTIVE_PATHS.md). A newer version's is neither read nor written (docs/UPDATES.md §4) |

The setting: the profile's settings → Data → **Keep cookie snapshots and restore lost cookies**
(`ProfileConfiguration.cookieRecovery`), on by default; written into `config.bin` only when it is off,
so a profile that keeps it on is stored as before. Turning it off removes the snapshots and the mark
(at the save, and at the next launch for a change that came by sync); a run under way stops copying
at its next look.

## When a snapshot is taken

Where the profile runs — its own process, or the app's in the sandboxed build — and through
`WKHTTPCookieStore` (`getAllCookies`), as the store holds them in memory:

| When | Taken | Why |
|---|---|---|
| Every 30 s while it runs | when the cookies differ from the newest snapshot (a cookie added, removed, or with another value or expiry; an expiry within a second aside, a cookie that expired and the store dropped is no change) **and** the newest is 3 minutes old — or at once when the store kept fewer than half of the newest snapshot's cookies | A look costs one read of the store; a copy is written at most every 3 minutes. A mass removal while it runs is someone's choice — a clear, the sign-out of the one site that set most of them — since a store does not lose cookies in a running process: copied at once, so that a crash right after does not undo it |
| At a clean stop | when the cookies differ | After the session cookies are deleted and the store wrote its cookies to disk, after sync recorded the run, before the seal: the newest snapshot is then the store as it is sealed |
| After Lumen's own change | when the cookies differ | A cookie import into the running profile (Import Cookies, the automation API, a restore by hand), WebDriver's `addCookie`, `deleteCookie`, `deleteCookies`: the snapshot follows at once, so that neither a crash loses the change, nor a restore brings back what it deleted or replaced |
| At a launch that changed the store | when the cookies differ | Cookies put back from a snapshot, synced cookies applied, imported cookies put in: the profile's state now |

Never a first snapshot of nothing. Copies of one profile never overlap: a look and an import's copy
that came together would otherwise copy the same cookies twice.

The running mark is removed at a clean stop only once its last snapshot was written (or none was
due); a stop whose copy failed keeps it, and the next launch is then treated as after a crash.

## When a launch puts cookies back

At every launch of a persistent profile with the setting on, after its website data is unsealed and
before anything reads its store:

1. **The disk, before the store exists** (`CookieSnapshotKeeper.storeState`, before CFNetwork reads
   — and rewrites — the cookie file): no website data at all (no archive, nothing an earlier run left)
   is a **missing** store. Otherwise each `*.binarycookies` file of the profile's WebKit directories is
   checked as holding together (`BinaryCookiesFile`: its pages and records within the file, counted,
   never read): WebKit's file that does not hold together is a **damaged** store. A file of a format not
   known here (another signature, another page layout) says nothing either way.
2. **The store, once it exists** — before synced cookies, imported cookies or the first page
   (`CookieSnapshotKeeper.recover`, `CookieRecovery.decide`) — is compared with the newest snapshot:

| The store | The last run ended | Put back |
|---|---|---|
| missing, or its cookie file damaged | either way | every cookie of the snapshot the store lacks |
| present | cleanly (no mark) | every cookie of the snapshot the store lacks — the snapshot is the store as it was sealed, and nothing changes a sealed store: a cookie it lacks now was lost (a write CFNetwork never made, damage the check could not see), not deleted |
| present | uncleanly (the mark) | only when the store kept **fewer than half** of the snapshot's cookies; then every one it lacks |
| any | any | nothing when the snapshot holds no cookie still valid, or the store has every one of them |

"Lacks" is by name, domain (host-only or not) and path: a cookie the store has, with any value, is
left as it is — its value is the newer one. Never a cookie that has expired, never a session cookie
(snapshots hold none). Only the newest snapshot decides; the ones before it are for a restore by hand.

Why "fewer than half" after an unclean end, and not any cookie missing: the newest snapshot may be up
to three minutes older than the store's last state. What a site or the person did since — a sign-out,
a deletion — is theirs and stays; a mass removal was copied at once (above). What is left: a site that
removes most of the profile's cookies within the half-minute before a crash comes back. A crash that
took only the last few cookies set (a sign-in a moment before it) is not put back by itself; the restore
by hand is there for that.

Put back through `CookieStoreImport` (what WebKit refused is counted), and written to disk at once.
The launch's cookies are then copied (a snapshot), the run is marked, and its store is looked at from
then on. Cookies WebKit kept none of are tried again at the next launch — unless a clean stop copies
the store first.

## The notice, the journal, the log

A launch that put cookies back says so in the profile's own window — Safari's when its chrome is
hosted, ours otherwise: **"Cookies were restored from a snapshot of ‹time›"**, and how many came back
(`cookieRecovery.notice`, in Russian and English). A small panel of its own, attached to the window,
over the top of the page: it never takes the keyboard or activates anything, goes by itself after 12
seconds, and closes with its button. Nothing of the window changes — not its toolbar, not the page's
size, which a page measures. A launch without a window (a warm-up, an export) says it when a window of
the profile first opens.

The manager is told once per launch (`ProfileEvent.cookiesRecovered`: the count, the cause, the
snapshot's time, whether the notice was shown — nothing of a cookie), and the profile's journal keeps
it: "Lost cookies restored from the snapshot of ‹time›".

The log says counts, causes, the snapshot's age and what the cookie file check found — never a
cookie's name, value or domain (scripts/check_log_privacy.py).

## By hand

The profile's menu and the inspector's Cookies menu: **Restore Cookies from a Snapshot…**
(`CookieSnapshotsView`) lists the snapshots, newest first, each with when it was taken and how many
of its cookies are still valid. **Restore…** asks first, saying what it does: the snapshot's cookies
that have not expired replace the profile's cookies of the same name, domain and path, and the others
stay; expired and session cookies are not restored. It is an import (`ProfileManager.importCookies`):
at once when the profile runs, in its own process — and copied at once, as any import — else queued,
encrypted, for its next launch, before its first page. The journal keeps it ("Cookies restored from
the snapshot of ‹time›"). An imported cookie that expired while it waited for the launch is not set:
setting it would delete the profile's own cookie of that name.

## With cookie sync, imports and restore points

Recovery runs **before** sync's launch step (docs/SYNC_FORMAT.md, Cookies), on the store as it came
up, and a store found to have lost cookies is recorded for sync as one (`CookieJarDocument.LaunchStore
.recovered`):

- **No deletion** is recorded for what it lacks: the loss is not the person's, and recorded it would
  take those cookies off every other device. The synced cookies applied next put back what the
  snapshot did not have.
- What it holds that the baseline did not, or held otherwise — the crashed run's changes, as the
  snapshot had them — is recorded as changes **of the baseline's time**, the earliest they can be.
  Any change another device made since this one last recorded wins over them, in the document and on
  every device, and is applied to the store before the first page: a snapshot never pushes a stale
  cookie over a newer one, and a cookie another device deleted since is deleted again here. A cookie
  the synced cookies do not know at all fills them in, once: recorded again it is the baseline's, and
  merges into one entry.
- A restore **by hand** is the person's own change: an import, recorded as a change of now, which the
  other devices get at the next sync — the confirmation says so when the profile syncs its cookies.
- No loop: a launch records the store after recovery and sync as its baseline; the next stop records
  only what the run changed; snapshots are never synced.

Imports: an import into a running profile is copied at once (it may replace cookies); one into a
stopped profile goes in at its launch, after recovery, and the launch's snapshot holds it. Restore
points carry the snapshots and the mark (above). A profile brought from another Mac (`.pbprofile`, a
vault brought back from sync) has no snapshot until it has run here.

## Ephemeral profiles

No snapshots, no mark, no restore: an ephemeral profile's store is `nonPersistent()` and is meant to
end with the run. A profile made ephemeral loses its snapshots at the save.

## What is verified where

- **Linux and macOS** (`swift test`): `CookieRecoveryTests` — when a snapshot is taken (first,
  unchanged, expired, periodic, clean stop, Lumen's change, mass removal, clock set back), when a launch
  puts back and what (missing, damaged, clean end, unclean end with a sign-out or a far-fewer store, the
  threshold, expired and session cookies, host-only against domain cookies, only the newest snapshot),
  the clear and import cases end to end, rotation, and what a restore records for sync (no deletion,
  as of the baseline, never over another device's newer change, no duplicate);
  `CookieSnapshotFileTests` — sealed in the profile's folder (no value, name or domain readable;
  0600; no temporary file left), another profile's process cannot open them, rotation on disk,
  unreadable moved aside, a newer version's left alone, the running mark, the setting off, restore
  points; `BinaryCookiesFileTests` — the cookie file's check on files made to the format.
- **macOS only** (the self-test, group `cookie recovery`; docs/CI.md): in the app's process (both
  builds) — an import copied at once and sealed, the mark while running and gone after a clean stop;
  the website data removed, then the cookie file damaged (WebKit's own file first checked as holding
  together, with its records counted): each time the profile's first request carries the cookies
  again; cookies deleted through WebDriver copied at once and not brought back when the store is lost
  after; an ephemeral profile keeps none. In a profile's own process (the unsandboxed build) — the
  process killed with SIGKILL and its cookie file damaged: the cookies are back at the next launch, the
  notice shown in its window; then deleted through WebDriver, killed and damaged again: nothing comes
  back.
