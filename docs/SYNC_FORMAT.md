# Sync format (client side)

Sync is optional, off by default, and works on demand (**More → Sync…** in the app). This
document describes the client: wire format, objects and merge rules. The HTTP contract
for a server is in [SYNC_SERVER_API.md](SYNC_SERVER_API.md). A server and an account page are
built to the decisions below.

## Where a Mac syncs to

`DeviceSettings.SyncTarget`, chosen in **Settings → Sync** (or **More → Sync…**); one at a time, the
same vault and the same objects whichever it is:

| Target | Transport | What is typed in | Stored in `settings.bin` |
|---|---|---|---|
| **Lumen account** (`.account`) | `HTTPSyncTransport` at the account server (`PBAccountServerURL`), `Authorization: Bearer` this Mac's device token from `account.json` (`AccountSync`; the account server's CONTRACT §16.1) | nothing | the choice only: `{"account": {}}` |
| **Folder** (`.folder`) | `LocalDirectorySyncTransport`: local-only, a NAS share or an external disk | a folder | a security-scoped bookmark and the path |
| **Own server** (`.server`) | `HTTPSyncTransport`: a server of one's own that speaks SYNC_SERVER_API.md | its HTTPS address and an access token | the address and the token |

**Lumen account** is offered while this Mac is signed in to an account (`AccountSync.isOffered`),
but not on an account the server has disabled. The server takes sync requests only while a paid plan
runs (its CONTRACT §16, the owner's decision of 15 November 2026, since v2026.11.15): on the trial,
without a plan and after the paid period ended it answers `403 sync_not_in_plan`, which the app says
as a state; a payer's data stays there and syncs again after a payment, and the space follows the
plan, 100 MiB at least. The vault's encryption is exactly the other targets': the server receives
ciphertext and the plaintext `vault-header` only, and the key never leaves the user's devices. Lumen
for iPhone signed in to the same account finds this vault with `GET /v1/device/sync/vaults` and opens
it with the master password; the vault's id in the URL is the vault's own (`UnlockedVault.vaultID`),
the one its header names. A Mac that has no vault finds it the same way and brings it back — or joins
it, while another Mac goes on syncing it (*A Mac without a vault*, below); a Mac that makes a vault of
its own syncs that one, and the server keeps up to 3 vaults per account.

Sync through the account:
- **Waits for the license.** The first sync after the app starts follows a renewal of the document
  of rights that reached the server with this Mac still signed in (`LicenseModel.renewForSync`,
  CONTRACT §16.1): a token copied to another Mac with the app's files is `device_revoked` or
  `machine_mismatch` by then, and gone (§9.4). A `401` from the sync renews again, which signs an
  unlinked Mac out. Signed out, the target stays and nothing syncs: the status says to sign in.
- **Says the server's refusals as states**, in both languages, and changes nothing on this Mac for
  any of them: `403 forbidden` (the vault is another account's), `too_many_vaults`,
  `account_disabled`, `sync_on_hold` (no request before its `availableAt`, kept in the status),
  `sync_not_in_plan` (no paid plan running: the trial, no plan, a paid period that ended), `429`.
  `507 quota_exceeded` and
  `413 too_large` are about one object: it waits (`SyncReport.deferredOverQuota`,
  `deferredTooLarge`), the rest syncs, and the status says the plan's space is full, with the
  account page a click away; or, for one too large, which profile's settings or files wait
  (`SyncReport.tooLargeByProfile`) and why — the settings hold the camera's image and video, and
  a smaller video makes them sync (below).
- **`409 generation_changed`** stops the run with nothing more written and nothing said; the app
  runs again at once, once, and that run starts over (below).

## Accepted decisions for a server (October 2026)

Accepted by the project's owner before any server exists, so that a server and its account page
are built to them rather than around them. Where the client already does what a decision says,
that is said; the rest is not built yet.

1. **Sync traffic goes directly, never through a profile's proxy.** Sync is the app's own
   connection, from the profile manager (today `HTTPSyncTransport` over the app's `URLSession`;
   no profile's proxy is on that path). Through a profile's proxy it would spend traffic the user
   pays for — a profile's state is hundreds of kilobytes per change, and residential proxies are
   sold by the gigabyte — make sync slow and unreliable, and fail wherever a proxy blocks the sync
   domain, as the owner's proxy blocked ipinfo.io. The protection is not in the route but in the
   server having nothing to link (decision 3).

2. **One connection per app, not per profile.** The app syncs the objects of every profile in one
   batched run. The server learns "this account has changes", never "profile N is open now, from
   here". A connection per profile on a timer — the competitor's: every profile calls its server
   every five seconds, so the server knows which profile a person has open this second, and from
   which address — is ruled out on purpose.
   The lock that keeps one profile from running on two Macs at once is needed (cookies otherwise
   diverge: *Limitations*), and it is a **lease**, not a live signal: taken during a sync, as one
   more encrypted object written with compare-and-swap, the device and the expiry inside its
   ciphertext; released by a later sync, and otherwise ending when it expires. It is never renewed
   on a timer and never opens a connection of its own — coarser than a live lock, and silent.

3. **The server stores ciphertext only; the key never leaves the user's devices.** As built:
   every object but `vault-header` is encrypted end to end (*Envelope*), object IDs are opaque
   HMACs, and the server knows no profile's name, tags, notes or proxy address. A server or an
   account page does not step back from this for convenience. A list of profiles in the account
   page, a search across profiles, a preview, a count by kind: each needs the server to understand
   the content, and with the first of them the promise ends. Anything the account page cannot do
   without reading content is brought to the owner as a question, never decided in code.

4. **Off by default.** As built: sync stays off until the user sets a target. Sending cookies to
   someone else's server is a deliberate act, never a default: most users have one Mac and gain
   nothing from sync, so on by default would be risk for no benefit. Turning it on first shows an
   honest screen (not built yet):
   - what leaves the Mac: the profile list, each profile's settings with its proxy and its
     credentials, passwords, bookmarks, history, and persistent cookies (for the profiles whose
     **Sync cookies with other devices** switch is on) — all of it encrypted on the Mac;
   - what the server sees: the account, the vault ID and its header (the KDF's salt and
     parameters and the wrapped key, nothing secret), how many objects there are, their sizes and
     revisions, when they change, and the address the Mac connects from — its own, not a
     profile's proxy;
   - what it never sees: profile names, sites and URLs, cookies, passwords, proxies, anything
     inside.

5. **Metadata kept by the server is decided explicitly, with the server.** What it keeps in its
   logs — addresses, times, sizes — is decided before it runs and written here as "this, for this
   long; nothing else", never "whatever the stack keeps". Open.

**Why this is written now.** The comparison it is for: the competitor's server knows the person,
their real address, which profile is open this second, and receives the profile's data (the
owner's measurement on a live Mac; not repeated in this repository). This project's server will
know that an account exists, that it has changes, the address they come from and their size —
and does not and cannot know what is inside. That difference can be said on the website, and a
buyer can check it the same way the competitor was checked.

## What is ready for a server vs. local-only

| Layer | Code | Status |
|---|---|---|
| Wire format: envelope, opaque object IDs, AAD binding | `SyncEnvelope.swift` | ready (`pbsync-2` written since the vault's generation 2; `pbsync-1` still read) |
| Engine: CAS writes, deferral, tombstones, per-record merges | `SyncEngine.swift` | ready, unit-tested |
| Backend contract | `SyncTransport` protocol | ready; this is all a backend implements |
| `HTTPSyncTransport` | `Sync/Transports/HTTPSyncTransport.swift` | client: speaks SYNC_SERVER_API.md and the Lumen server's generation header and error bodies; tested against in-process stubs (`StubSyncServer`, `GenerationStubServer`) |
| Sync through the Lumen account | `Sync/AccountSync.swift`, `AppModel.syncNow` | the account server with the device token; built to the account server's CONTRACT §16; not run against the live server from this repository |
| `LocalDirectorySyncTransport` | `Sync/Transports/LocalDirectorySyncTransport.swift` | **local-only**: a folder (NAS share, external disk); CAS is atomic within one process only |
| Sync target and last status | `DeviceSettings` (`settings.bin`, encrypted, never synced) | ready; folders are kept as security-scoped bookmarks so access survives relaunch in the App Sandbox |

## Backend contract

```swift
public protocol SyncTransport: Sendable {
    func listObjects() async throws -> [RemoteObjectInfo]      // (objectID, revision)
    func fetch(objectID: String) async throws -> Data?
    // Compare-and-swap: succeed only if the current remote revision == expectedRevision
    // (nil = object must not exist); otherwise throw CoreError.syncConflict.
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws
}
```

Any store with conditional writes works: the REST API in SYNC_SERVER_API.md, S3
`If-Match` / `If-None-Match`, WebDAV ETags, or CloudKit record change tags. The server
never needs to parse a blob.

## Objects

| Object ID | Content | Encrypted |
|---|---|---|
| `vault-header` | `VaultHeader` JSON: vault ID, KDF params, salt, wrapped VMK, `passwordRevision` (how many times the master password was changed) | no, it contains nothing secret, and a new device needs it to derive the key |
| `HMAC(objectIDKey, "index")` | envelope → profile index | yes |
| `HMAC(objectIDKey, "labels")` | envelope → the tags' colours (`TagColors`, `labels.bin`): one choice per tag for the whole vault, not part of any profile's settings | yes |
| `HMAC(objectIDKey, "profile/<uuid>/config")` | envelope → the profile's `config.bin` bytes | yes (twice) |
| `HMAC(objectIDKey, "profile/<uuid>/passwords")` | envelope → the profile's `passwords.bin` bytes | yes (twice) |
| `HMAC(objectIDKey, "profile/<uuid>/bookmarks")` | envelope → the profile's `bookmarks.bin` bytes | yes (twice) |
| `HMAC(objectIDKey, "profile/<uuid>/history")` | envelope → the profile's `history.bin` bytes | yes (twice) |
| `HMAC(objectIDKey, "profile/<uuid>/cookies")` | envelope → the profile's `cookies.bin` bytes: its persistent cookies (see [Cookies](#cookies)) | yes (twice) |

The rest of the WebKit website data (localStorage, IndexedDB, caches, service workers) is
**not** synced. Its archive is large and only consistent while the profile is stopped;
supporting it means adding an object type that carries `webdata.pbsa`. Cookies sync on their
own through `cookies.bin`, cookie by cookie.

## Envelope

```json
{
  "format": "pbsync-2",
  "vaultID": "7C1E…",
  "objectID": "3f9a…(64 hex)",
  "revision": 7,
  "ciphertext": "base64( nonce(12) | AES-256-GCM(envelopeKey, payload) | tag(16) )"
}
```

- `AAD = "<format>|<vaultID>|<objectID>|<revision>"`. The server can't move a blob to
  another object ID or replay it under a different revision.
- `pbsync-2` came with the vault's generation 2 (docs/UPDATES.md §4, R3): the versions before it
  read only `pbsync-1` and look at nothing else on the sync location, so a new envelope is what
  stops them there. This version reads both and writes `pbsync-2`; when it raises a vault's
  generation it also raises the header on the sync location.
- `payload = {"logicalName": "...", "deleted": false, "data": "<base64>"}`. After
  decrypting, the client checks that `HMAC(objectIDKey, logicalName) == objectID`.
- `envelopeKey = HKDF(VMK, "sync-envelope")` and `objectIDKey = HKDF(VMK, "sync-object-id")`.

**The server learns:** the vault ID, how many objects exist, their sizes, their revision
counters, and when they change.

**The server doesn't learn:** profile names or count (the object count is a rough upper
bound), settings, proxy credentials, passwords, URLs, or cookies (names, values, domains).

## Engine algorithm

The engine keeps per-object local state in `sync-state.bin`, encrypted: the last synced
revision and the SHA-256 of the last synced bytes; the place those records are of — a server's
address and the vault, or a folder's path (`SyncEngine.place(of:)`); and, from a server that keeps a
generation of its data (`ServerGenerationTransport`: the Lumen server), the generation those records
are of. Format 2 with a generation (its server and vault are the place: what the version that
brought generations reads); format 3 with a place and no generation (a folder, a server of one's
own that keeps none), which a version from before places refuses rather than take another place's
copies for newer; format 1, the map of records alone as every version before wrote it, names no
place.

0. **Start over when the records are not of the sync location's data** (the account server's
   CONTRACT §16.2). The records are of one place: kept for another — the account after a folder, a
   folder after the account, a folder or server used before, any other folder or server — or for
   none said (format 1, kept by a version from before places: the first sync after the update), they
   are forgotten, and this place kept with them. Another place's revisions say nothing of this
   one's: a folder used for months before the account holds older copies at higher revisions than
   the vault the account made anew, and the account's records took them for newer — which a
   version before this one pulled over this Mac's newer files. The list names the server's
   generation (`X-Lumen-Server-Generation`: 32 hex, or `none` when the server has no such vault).
   Another one than the one kept — the server's database put back from a copy, its sync data deleted
   on the account page, or the first run of a client that knows of generations — and the records
   are forgotten, the new one kept. Whatever the place and generation, an object the records name
   that is missing from the list or listed at a lower revision forgets them too (a disk snapshot put
   back, a file removed): objects are never deleted one by one there, and revisions only grow. A
   server that names no generation is spoken to as before, and a generation kept for another address
   is dropped. Forgotten records mean every
   object counts as changed here, and the steps below do the rest: what only this device has goes
   up (`If-None-Match: *`), what both have is merged — a config by its times, the other version kept
   beside it; without times, or equal ones, **this device's stays** and the server's is kept beside
   it, in a file of its own, never over one kept before — and what only the server has comes down.
   No object is taken from the server only because its revision differs from a forgotten record.
   Local data is never touched by the step itself (`SyncReport.startedOver`). Every write of the run
   names the generation (`none` too); a write the server accepts may name a new one (the vault made
   anew), which is the run's from then on. `409 generation_changed` stops the run: nothing more is
   written, the records stay as they are, and the next run starts over.
1. Publish `vault-header` if it is absent. If the server's header has a different vault
   ID, refuse; if a newer version of the app wrote it (its `format`), stop with
   `CoreError.newerFormat` — this device needs that version first (docs/UPDATES.md §4).
   Otherwise publish this device's header when it is the newer: more master-password changes
   (`passwordRevision`), or as many with the same wrapped key and a higher `format` (R3). One
   with fewer changes, or as many with another key (changed apart, or before changes were
   counted), is never published over the server's; the report says which
   (`SyncReport.passwordHeader`), and the sync goes on.
2. **Index:** if the remote revision changed, fetch it and merge with the local index:
   the union by profile ID, the higher summary revision wins, and profiles in either
   side's `deletedProfileIDs` are dropped (their folders on this Mac are kept, for the person to
   bring back as a new profile or remove: R3, docs/DESTRUCTIVE_PATHS.md). Save the result locally, and push it if it
   differs from the remote copy. If only the local index changed, push it. A local index that
   was not read (missing or unreadable, `ProfileRepository.IndexState`) is never pushed: the
   remote one is fetched and merged whatever its revision (docs/ARCHITECTURE.md, `index.bin`
   missing or unreadable).
3. **Per-profile files**, for each profile in the merged index:
   - local change only → push (`revision = remote + 1`, CAS on the remote revision) — but
     **config** older than the server's (by `settingsModifiedAt`, settings that differ) is not an
     edit: a version put back from a backup (R2). The server's stays the settings, this device's is
     kept as a version (`KeptSettings.Origin.restored`, `report.restoredSettings`) and never pushed
     over the newer ones; and
     **bookmarks**, **history** and **cookies** are merged with the remote copy when there is
     one, as if both had changed: a file this device lost and made anew holds only what was
     added since, and pushed as it was it took everything else off every other device
   - remote change only → pull and write the file atomically
   - both changed:
     - **bookmarks**, **history** and **cookies** are merged record by record (see below)
       and the result is pushed (`report.merged`);
     - **config**: the newer settings win, by `settingsModifiedAt` (when the user last
       changed them); the other version is kept on the device that ran the sync, whichever side
       won (`report.resolvedConflicts`), in a file of its own — `config.bin.conflict`, then `-2`,
       `-3`… — never written over, with where it is from and when (`KeptSettings`); the person
       uses or removes it in the profile's editor, and past five the sync asks them to go through
       them (`report.settingsVersionsToReview`), removing none. When the two differ
       only in what the browser keeps for itself (`lastProxyLocation`, found at a launch),
       the remote file is taken, with no copy and no conflict reported. A version with the
       time beats one without (never edited since it was created, or rewritten by an older
       build); with neither or equal times, the resolver decides, as for passwords;
     - **passwords** are merged login by login (`passwords.bin` format 2, see below) — and so
       is a password file that changed only here while the server holds one, as for the other
       mergeable files.
4. Delete local directories of profiles removed from the index, and report their IDs so
   the app also removes their WebKit stores.

A lost CAS race leaves the object in `report.deferred`; the next sync retries it. So does a write
the server refuses for that object alone — `413` (too large) or `507` (no room left in the plan's
sync space): the object waits (`report.deferredTooLarge`, `report.deferredOverQuota`) and the run
goes on with the rest. The Lumen server takes 16 MiB an object. A profile's settings (`config.bin`)
hold its camera's image and video, whose bytes the object carries about 2.48 times over (base64 in
the settings' JSON, in the payload and in the envelope, each 4/3, and a `\/` for one character in
64): the editor keeps the two together within `CameraSubstitution.maxMediaBytes` (6 MiB, a 14.9 MiB
object). A profile saved before with more — a video of up to 12 MiB was taken — keeps working on
its Mac, and its settings wait at every sync; the app names the profile and says to choose a
smaller video.

A profile file this device cannot open — damaged, cut short, under another key — is handled before
any of the above, and never pushed: it once was, over the server's good copy of the settings, which
was then on no device at all, and with it the way back by Sync Now. When the server holds a copy
that opens, that copy is taken, and this device's is moved beside it as `<file>.unreadable` (then
`-2`, …): nothing unreadable is deleted or written over. When the server has none that opens,
nothing is written on either side. Either way `report.unreadable` names the file, and the app says
which and what was done. Settings (`config.bin`) missing here are taken back from the server even
when its copy has not changed since this device last had it: the profile does not start without
them (docs/DESTRUCTIVE_PATHS.md, R1).

Before a remote copy is pulled, merged, compared or written over — and before this device's copy
is merged or compared with it — its `format` is checked (the index's, and each profile file's
inside its envelope). A copy a newer version wrote stops the sync with `CoreError.newerFormat`:
it is neither merged nor written over, on either side. So does a `sync-state.bin` a newer version
wrote, before anything is fetched. The rules for each file: docs/UPDATES.md §4.

### Merge rules

Both documents carry tombstones, so a deletion on one device is not undone by a union with
another device's copy. Merges are idempotent (`merge(x, x) == x`) and unit-tested.

| Object | Identity | Conflicting versions | Deletions |
|---|---|---|---|
| Profile index | profile UUID | higher `revision` wins | `deletedProfileIDs` (permanent) |
| Bookmarks | bookmark UUID | newer `updatedAt` wins | `deleted[id] = time`; a version edited *after* the deletion survives |
| History | normalised URL | `lastVisitedAt` = max, `visitCount` = max (not sum: the same visits exist on both sides), title of the newest visit | `removedURLs[url] = time` drops visits not newer than it; "Clear all" sets a `clearedThrough` watermark |
| Cookies | name, domain (leading dot for a domain cookie, none for host-only), path — as a cookie store keys them | newer `updatedAt` wins; on the same second a deletion wins, then the larger value, the later expiry, then the flags (Secure, HttpOnly, SameSite), so the result does not depend on which device merges | `deleted[] = (key, deletedAt)`; a cookie set *after* its deletion elsewhere comes back |
| Settings (`config`) | the whole file | newer `settingsModifiedAt` wins; the other kept as `config.bin.conflict` | — |
| Tags' colours (`labels`) | the tag's name in lower case | later `chosenAt` wins; at the same moment a colour over none, then the lower colour | a colour taken away is a choice with no colour (`color: nil`), kept: a later one wins over it as over any |

A version of the app from before the tags' colours does not know the `labels` object: it never
reads it, and never writes it back without what it did not know. On a device, a `labels.bin` that
does not open is never pushed: the server's copy is taken in and the one here kept beside it as
`labels.bin.unreadable`.

History tombstones older than the profile's retention window are dropped, because no
surviving entry can be that old. Cookie tombstones are dropped after 400 days (no browser keeps
a cookie longer), and cookies once they expire.

## Cookies

`cookies.bin` is `AES-GCM(HKDF(profileKey, "cookies"), CookieJarDocument JSON)` with AAD
`cookies:v1:<uuid>`:

```json
{ "format": 1,
  "cookies": [ { "cookie": { "name": "sid", "value": "…", "domain": "example.com", "hostOnly": false, "path": "/",
                             "expires": "2027-01-01T00:00:00Z", "secure": true, "httpOnly": true, "sameSite": "lax" },
                 "updatedAt": "2026-10-27T09:30:12Z" } ],
  "deleted": [ { "key": { "name": "old", "domain": ".example.com", "path": "/" }, "deletedAt": "2026-10-27T09:30:12Z" } ] }
```

Only **persistent** cookies are in it: session cookies end with the run that set them, on
every device. An ephemeral profile has none, and a profile whose **Sync cookies with other
devices** switch is off (on by default) keeps an empty document, so that turning it off
empties the synced cookies on every device at the next sync (their cookie stores keep what
they hold; sync stops changing them).

A cookie store does not say when it changed a cookie, so each device keeps
`cookies-baseline.bin` (`HKDF(profileKey, "cookie-baseline")`, AAD `cookie-baseline:v1:<uuid>`,
**never synced**): the persistent cookies its store held when it last recorded or applied the
document. Changes are the difference between the store and that baseline:

- **Stop** (after the store wrote its cookies to disk, before the website data is sealed):
  every cookie added, changed or deleted since the baseline is written into the document as a
  change of now; then the baseline becomes the store. A cookie that expired is no deletion
  (each store drops it by itself).
- **Launch** (the profile's store exists, no page has loaded):
  0. cookie recovery (docs/COOKIE_RECOVERY.md) first: a store that lost cookies — missing website
     data, a damaged cookie file, cookies gone after a clean end, far fewer after a run that did not
     stop cleanly — is given back from this Mac's newest snapshot (never synced) every cookie it
     lacks. Such a store records **no deletion** in step 1 — the loss is not the person's, and
     recorded it would take those cookies off every other device — but for what this Mac's newest
     snapshot, when it is at least as new as the baseline, says was deleted since (a sign-out, a
     deletion through Lumen the lost store had not written): the store with that snapshot is taken
     for what the run left. What it holds otherwise is recorded as of the baseline's time, as below: any change another device made since wins, and
     step 2 applies it before the first page, so a snapshot never pushes a stale cookie over a newer
     one nor brings back one deleted elsewhere;
  1. what the store changed since the baseline without being recorded (a run that ended
     without a stop) is recorded as changes of the baseline's time, the earliest they can
     be. With no baseline yet (cookie sync just turned on, or the first launch on this Mac),
     the store's cookies are recorded as changes of the earliest possible time: they fill in
     what the document lacks, and any synced change wins over them. A store that came up with
     nothing — no website data archive and no plaintext an earlier run left: the data lost — records
     nothing: it is not every cookie deleted (which took them out of the document and, through
     sync, off every other device), and step 2 puts the document's cookies back;
  2. the document — with what sync merged in from the other devices — is applied to the
     store: its cookies set where the store has none or another version, its deletions
     deleted; store cookies the document does not know are left alone. A cookie WebKit
     refuses stays in the document;
  3. cookies imported while the profile was stopped (`cookies-import.bin`) go in, and are
     recorded as changes of now — so they reach the other devices at the next sync;
  4. the document is saved (only when it changed, so that an idle launch uploads nothing)
     and the baseline becomes the store.

A recorded change never overwrites a newer one already in the document (from another device,
merged by sync but not applied yet). Applying a document entry is not a change of this
device. Times are whole seconds.

A restore of a snapshot by hand (Restore Cookies from a Snapshot…) is the person's own change: an
import, recorded as a change of now at the next launch or stop, which the other devices get at the
next sync.

## A Mac without a vault

A new Mac, a Mac whose disk was erased, a second Mac: beside creating a vault, the setup screen
offers **I already have a vault** (`RestoreFlow`, `RestoreModel`; the core is `VaultRestore`). The
vault a Mac synced is brought to this one, and this Mac goes on with it — the same vault, not a new
one beside it. It is offered only where this Mac has no `vault.json`: at the first launch, and after
"Forgot password…" on the lock screen, which moves the vault's folder aside and never deletes it
(the way to replace a vault a Mac already made with the synced one).

```swift
let header = try await VaultRestore.header(at: t, expecting: vaultID)        // plaintext: dates, nothing secret
let staged = try VaultRestore.open(header, password: pw, root: root)         // verifies the password; makes the staging
let names  = try await VaultRestore.profiles(of: staged.vault, at: t)        // the index, read with the vault's key
let result = try await VaultRestore.download(into: staged.vault, from: t, target: target)
let vault  = try VaultRestore.moveIntoPlace(staged.vault, root: root)        // by journaled renames, vault.json last
```

**Where it is, and which one.**

| Place | How the vault is found | What is typed |
|---|---|---|
| Lumen account | `GET /v1/device/sync/vaults` with this Mac's device token (CONTRACT §16.1), after a renewal of this run, as a sync | nothing: the first launch's sign-in comes before the setup screen |
| Sync folder | the folder's `vault-header` | the folder |
| Server of one's own | SYNC_SERVER_API.md has no list of vaults | the address, the token and the vault's ID (shown under Settings → Sync on a Mac that syncs to such a server; it is the name the server keeps the vault under) |

The Lumen server names a vault by its ID and when it was last written to, nothing more. The app reads
each listed vault's plaintext header and shows what tells two vaults apart before any password: when
the vault was made, when it last changed, the start of its ID, and whether a newer version of the app
wrote it (it is then not offered: this Mac needs that version first, docs/UPDATES.md §4). Once the
master password has opened the header, the index is read with the vault's key, and the names of its
profiles are shown before anything is moved into place.

**What is kept where before there is a vault.** Nothing new. The device token is in `account.json`
as before (the rights are decided with it before a vault opens); the account's session stays in
memory and is sealed into the vault when it opens (`AccountSessionVault`); the master password is
held only while it opens the header; a server's token typed here goes into the restored vault's
`settings.bin`, encrypted, and nowhere else.

**What the server may answer** — each said as a state, in both languages, with what was and was not
changed (`AccountVaults.State`): no vault on the account; `sync_not_in_plan` (sync is the server's
only while a paid plan runs: a trial account has nothing there, a payer's vaults are there again
after a payment); `sync_on_hold` with the date it opens for a device new to the account;
`account_disabled`; `401` (this Mac is not signed in any more: the license is renewed, which says
why); `429`; no answer.

**How it is brought** (`VaultRestore`):

- **Nothing at the sync location is written.** The engine's own run goes through
  `ReadOnlySyncTransport`: every read as the transport makes it, no write at all. What the engine
  would have written (an index it merged into another order) is left for the first ordinary sync.
- **Never half a vault.** The vault is built in `restore-staging/<vault id>/` inside the vault's
  folder and moved into place only once the run ended with every listed file of the index's profiles
  here: by renames written down first (`move.json`), `vault.json` the last. A move cut short — the
  app quit, the power lost — is finished at the app's next start, before it looks for a vault
  (`VaultRestore.finishInterruptedMoves`).
- **Nothing here is written over.** Refused where this Mac has a vault; refused, with the names,
  where the vault's folder holds a vault's files without their `vault.json`, before the download
  and again before the move. What else the folder holds (`account.json`) is not touched.
- **Not from the beginning again.** The staging keeps the engine's own `sync-state.bin`: after a
  lost connection, the person's Stop or a quit, the same restore asked again fetches only what is
  not here yet. A master password changed on another Mac meanwhile is the one that opens it then.
  What an unfinished restore downloaded goes only by the person's own Discard on that screen
  (`VaultRestore.discardStagingBecauseThePersonAsked`; docs/DESTRUCTIVE_PATHS.md) — not by a failed
  run, not by a vault created instead, not at the app's start.
- **Room on the disk.** Asked for before it begins: the folder's size where the place is a folder,
  and 64 MiB to spare (a server says no size before the objects come); a disk that fills during the
  run is said as that, and what came is kept.
- **A newer version's vault** is refused before the password (its header) and during the run (any
  file of it): nothing is moved into place, and what came is kept for after the update.
- **The place changing under the run** — its data deleted, or put back from a copy — is said, with
  what came kept. The records the restore leaves are of the place and of the server's generation it
  read (CONTRACT §16.2), so the first sync after it goes on from them and starts nothing over.
- **This Mac goes on with that vault.** The place is this Mac's sync target from the start, in the
  restored `settings.bin`; the profiles count as synced ones (`SyncProfileToken`), one place of the
  license's each, on every device of the vault.
- **What the place did not have is named.** A profile the index lists whose settings never reached
  the place (refused as too large: the camera's video) is in the list and does not start; the last
  screen names it and says what sends its settings.

**What does not come**, because it is not synced: the website data other than cookies and the open
tabs, proxies of the list that no profile uses (each profile's own proxy is in its settings, and is
taken into the list at the first unlock), scenarios, warm-up plans, virtual machines, this Mac's own
settings.

**Two Macs on one vault.** Supported by the engine and tested as two devices throughout
(`SyncEngine`'s merges; the server counts a profile synced on several devices once, CONTRACT §6.2).
What is not built is the lease of decision 2: nothing keeps one profile from running on two Macs at
once, and its cookies then follow the Mac that stopped last (*Limitations*). Sync stays on demand.
The master password's screen says exactly this before the vault is brought.

`SyncEngine.bootstrap` remains for the tests and tools that set a second device up in place; the app
does not use it: it writes the header into the vault's folder before the first sync, and a run that
then failed left an empty vault that looked like a real one.

## Limitations

- No rollback protection across devices against a server that hides it. A server can serve an
  older complete set of blobs with their original revisions. An honest server that goes back — the
  Lumen server after its database is restored from a copy — says so with a new generation, and a
  set older than the device's records is noticed by its revisions (Engine algorithm, step 0); a
  server set on deceiving cannot be caught without a signed, monotonic manifest, or a counter kept
  on a trusted device.
- `LocalDirectorySyncTransport` CAS is atomic only within one process. File-syncing
  services can still produce conflict copies, which the transport ignores.
- A master-password change wraps the same VMK anew and counts the change in the header
  (`passwordRevision`). The app puts the header on the sync location right after the change
  (`publishVaultHeader()`), and every sync does when this device's is the newer (step 1): a new
  device sets up with the new password, not the old. The location keeps the header with the most
  changes; with as many, the first there stays (two changes made apart), and the other device says
  so. The VMK doesn't change, so devices on an older header go on syncing, and each keeps its own
  `vault.json`, which opens with the password it had: a copy of `vault.json` from before a change
  (on such a device, in a backup) opens everything with the old password, the data written after
  the change included (docs/ARCHITECTURE.md, Changing the master password).
- Run sync only while no profile is running, because incoming settings replace files on
  disk, not live sessions. The app enforces this: a sync first waits for profiles still
  starting or being encrypted (they read and write their synced cookies), and a launch asked
  for during a sync starts after it.
- Saved passwords merge login by login since `passwords.bin` format 2 (vault generation 2):
  each login carries its version and every version it was made from, and the file keeps its
  deletions. A login changed on one device after the other's version wins; one changed on two
  devices between syncs keeps both changes — the later in place, the other as a separate version
  of the same login (`conflictOf`), under an id made from its version (the same on every device,
  once), shown in the password manager to be chosen or deleted and never offered to a page. A
  deletion takes only the versions it saw: a change made elsewhere at the same time survives
  it. A fill is not a change (only `lastUsedAt`, the later of the two). Logins saved before
  versions get one derived from what they hold, so two devices holding the same login agree. Until
  then a concurrent edit kept the remote file and moved the local one to `passwords.bin.conflict`,
  which the next conflict replaced (`PasswordMergeTests`).
  - Which version stays the login is decided by the devices' clocks (`updatedAt`, ties by
    version): a hint for which to show first, never a reason to drop the other — clocks of two
    Macs need not agree. Each version says which Mac made it (`device`, the Mac's name) and when
    (by that Mac's clock); the password manager shows both, and numbers the versions kept beside
    one login. A kept version holds only what it is (its id comes from its version; no history,
    no last use), so two devices write it alike whatever order the copies met in, and no kept
    version is ever written over by another.
  - The same website and user name saved apart on two devices (two ids, one account) is folded
    into one login after a merge: the one changed last (a hint, ties by id) stays the login; the
    other is kept beside it as a version when its password, note or one-time code differs, and its id is
    tombstoned with the versions it had, so a device still holding it does not bring it back (a
    change it made there since comes back, and is folded again).
  - A login's one-time code (`totp`: the secret, the hash, the digits, the period) is part of the
    login and merges with it: adding or removing one is a change of the login like any other. A
    file that holds one is format 3, which a version from before codes refuses (it would write the
    login back without it) — that profile's passwords are then not merged on that device until it
    is updated; nothing of it is written over (docs/UPDATES.md §4).
  - A `passwords.bin.conflict` left by an earlier sync is taken in when the vault opens: each
    version in it that the file neither has, descends from, nor deleted becomes a version kept
    beside its login (one whose login is not there is kept beside its own id; choosing it makes
    it a login). The copy goes only once the file, read back, holds all of it; one that cannot be
    read stays as it is.
- The warm-up plan (`warmup.bin`) is not synced; the cookies and history its visits leave are,
  with the profile's.
- `cookies-import.bin` (cookies imported into a stopped profile, until its next launch) is not
  synced itself: it is applied on the Mac it was imported on, at the profile's next launch,
  and from there the cookies are in `cookies.bin` and sync with the rest.
- Cookies reach another device at its next **launch** of the profile, after a sync. A profile
  running on two Macs at once diverges until each stops; then the newer change of each cookie
  wins. The accepted remedy is a lease taken during a sync (decision 2), not built yet. A change counts from the stop that recorded it (or a launch, for imports), not from
  the moment the page set it: of two devices that changed the same cookie in overlapping
  runs, the one that stopped later wins.
- Only cookies sync. A site that keeps its sign-in in localStorage or IndexedDB (rather than
  a cookie) is signed in on one device only. SameSite=None and unspecified cookies are both
  set without the attribute (WebKit's default; Safari sends both cross-site). Partitioned
  (CHIPS) cookies do not sync: the public API cannot set one in its partition on the other
  device, and unpartitioned it would reach more sites (the store marks them with WebKit's
  `StoragePartition` property; as the cookie import, they are skipped).
- The settings' newer-wins rule needs `settingsModifiedAt`, written by this build on every
  change made in the editor, by "Never for This Website" and by removing a site from that list
  (not by what the browser stores itself, such as the proxy location). Saving the editor with
  nothing changed is no change. An older build drops the field (and `syncCookies`, which then
  reads as on, `searchEngine`, which then reads as DuckDuckGo, the profile's `tags`, `notes`
  and `avatar`, its `windowSize`, the `safariVersion` it names, `localRequests`,
  `languageOverride` and `localeSource`) when it rewrites a
  configuration, so its edit loses to one made by this build;
  two versions without the time, and edits within the same second, fall back to the resolver
  (`keepRemote`, local copy as `config.bin.conflict`).
- An older build skips the `cookies` object entirely: it neither uploads nor applies cookies,
  and leaves the object untouched for newer devices.
- The conflict copy (`config.bin.conflict`; `passwords.bin.conflict` from before format 2) is
  encrypted like the file and stays on that Mac; a later conflict replaces it. The app reports conflicts in the
  sync status but does not offer to restore a copy yet.
- `PasswordEntry.lastUsedAt` (when AutoFill last filled the login) and the configuration's
  `passwordAutoFill` / `passwordNeverSaveSites` are optional fields: an older build reads the
  files and drops them when it rewrites one (a login then loses its last-used date, a profile
  its "Never for This Website" list, and an AutoFill switch turned off is on again).
- Dates are encoded as ISO 8601 with whole seconds, so ordering within the same second is
  arbitrary.
