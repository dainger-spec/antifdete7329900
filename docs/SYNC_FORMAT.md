# Sync format (client side)

Sync is optional, off by default, and works on demand (**More → Sync…** in the app). This
document describes the client: wire format, objects and merge rules. The HTTP contract
for a server is in [SYNC_SERVER_API.md](SYNC_SERVER_API.md).

## What is ready for a server vs. local-only

| Layer | Code | Status |
|---|---|---|
| Wire format: envelope, opaque object IDs, AAD binding | `SyncEnvelope.swift` | ready, stable (`pbsync-1`) |
| Engine: CAS writes, deferral, tombstones, per-record merges | `SyncEngine.swift` | ready, unit-tested |
| Backend contract | `SyncTransport` protocol | ready; this is all a backend implements |
| `HTTPSyncTransport` | `Sync/Transports/HTTPSyncTransport.swift` | **server-ready client**: speaks SYNC_SERVER_API.md, tested against an in-process stub; no server included |
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
| `vault-header` | `VaultHeader` JSON: vault ID, KDF params, salt, wrapped VMK | no, it contains nothing secret, and a new device needs it to derive the key |
| `HMAC(objectIDKey, "index")` | envelope → profile index | yes |
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
  "format": "pbsync-1",
  "vaultID": "7C1E…",
  "objectID": "3f9a…(64 hex)",
  "revision": 7,
  "ciphertext": "base64( nonce(12) | AES-256-GCM(envelopeKey, payload) | tag(16) )"
}
```

- `AAD = "pbsync-1|<vaultID>|<objectID>|<revision>"`. The server can't move a blob to
  another object ID or replay it under a different revision.
- `payload = {"logicalName": "...", "deleted": false, "data": "<base64>"}`. After
  decrypting, the client checks that `HMAC(objectIDKey, logicalName) == objectID`.
- `envelopeKey = HKDF(VMK, "sync-envelope")` and `objectIDKey = HKDF(VMK, "sync-object-id")`.

**The server learns:** the vault ID, how many objects exist, their sizes, their revision
counters, and when they change.

**The server doesn't learn:** profile names or count (the object count is a rough upper
bound), settings, proxy credentials, passwords, URLs, or cookies (names, values, domains).

## Engine algorithm

The engine keeps per-object local state in `sync-state.bin`, encrypted: the last synced
revision and the SHA-256 of the last synced bytes.

1. Publish `vault-header` if it is absent. If the server's header has a different vault
   ID, refuse.
2. **Index:** if the remote revision changed, fetch it and merge with the local index:
   the union by profile ID, the higher summary revision wins, and profiles in either
   side's `deletedProfileIDs` are dropped. Save the result locally, and push it if it
   differs from the remote copy. If only the local index changed, push it.
3. **Per-profile files**, for each profile in the merged index:
   - local change only → push (`revision = remote + 1`, CAS on the remote revision)
   - remote change only → pull and write the file atomically
   - both changed:
     - **bookmarks**, **history** and **cookies** are merged record by record (see below)
       and the result is pushed (`report.merged`);
     - **config**: the newer settings win, by `settingsModifiedAt` (when the user last
       changed them); the other device's file is kept as `config.bin.conflict` on the device
       that ran the sync, whichever side won (`report.resolvedConflicts`). When the two differ
       only in what the browser keeps for itself (`lastProxyLocation`, found at a launch),
       the remote file is taken, with no copy and no conflict reported. A version with the
       time beats one without (never edited since it was created, or rewritten by an older
       build); with neither or equal times, the resolver decides, as for passwords;
     - **passwords** go to the resolver (default `keepRemote`; the local copy is kept as
       `<file>.conflict`, reported in `report.resolvedConflicts`).
4. Delete local directories of profiles removed from the index, and report their IDs so
   the app also removes their WebKit stores.

A lost CAS race leaves the object in `report.deferred`; the next sync retries it.

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
  1. what the store changed since the baseline without being recorded (a run that ended
     without a stop) is recorded as changes of the baseline's time, the earliest they can
     be. With no baseline yet (cookie sync just turned on, or the first launch on this Mac),
     the store's cookies are recorded as changes of the earliest possible time: they fill in
     what the document lacks, and any synced change wins over them;
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

## New device

```swift
let vault = try await SyncEngine.bootstrap(transport: t, root: root, password: pw) // verifies the password
let repo  = try ProfileRepository(vault: vault)
_ = try await SyncEngine(repository: repo, transport: t).sync()
```

## Limitations

- No rollback protection across devices. A server can serve an older complete set of
  blobs with their original revisions. Fixing this needs a signed, monotonic manifest,
  or a counter kept on a trusted device.
- `LocalDirectorySyncTransport` CAS is atomic only within one process. File-syncing
  services can still produce conflict copies, which the transport ignores.
- After a master-password change, call `publishVaultHeader()`. Devices still on the old
  header keep working with the old password until they fetch the new one. The VMK
  doesn't change.
- Run sync only while no profile is running, because incoming settings replace files on
  disk, not live sessions. The app enforces this: a sync first waits for profiles still
  starting or being encrypted (they read and write their synced cookies), and a launch asked
  for during a sync starts after it.
- Passwords are not merged per entry yet: concurrent edits on two devices resolve to the
  remote file, and the local one is kept as `passwords.bin.conflict`. Adding tombstones
  to `PasswordVault` would allow the same merge as bookmarks.
- `cookies-import.bin` (cookies imported into a stopped profile, until its next launch) is not
  synced itself: it is applied on the Mac it was imported on, at the profile's next launch,
  and from there the cookies are in `cookies.bin` and sync with the rest.
- Cookies reach another device at its next **launch** of the profile, after a sync. A profile
  running on two Macs at once diverges until each stops; then the newer change of each cookie
  wins. A change counts from the stop that recorded it (or a launch, for imports), not from
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
  reads as on) when it rewrites a configuration, so its edit loses to one made by this build;
  two versions without the time, and edits within the same second, fall back to the resolver
  (`keepRemote`, local copy as `config.bin.conflict`).
- An older build skips the `cookies` object entirely: it neither uploads nor applies cookies,
  and leaves the object untouched for newer devices.
- The conflict copy (`config.bin.conflict`, `passwords.bin.conflict`) is encrypted like the
  file and stays on that Mac; a later conflict replaces it. The app reports conflicts in the
  sync status but does not offer to restore a copy yet.
- `PasswordEntry.lastUsedAt` (when AutoFill last filled the login) and the configuration's
  `passwordAutoFill` / `passwordNeverSaveSites` are optional fields: an older build reads the
  files and drops them when it rewrites one (a login then loses its last-used date, a profile
  its "Never for This Website" list, and an AutoFill switch turned off is on again).
- Dates are encoded as ISO 8601 with whole seconds, so ordering within the same second is
  arbitrary.
