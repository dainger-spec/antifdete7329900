# Sync format (client side)

Sync is optional. The client is complete (`SyncCodec`, `SyncEngine`). The only bundled
backend is a folder (`LocalDirectorySyncTransport`), for example on a NAS, an external
disk, or a cloud-drive folder. A real server only needs to implement `SyncTransport`.

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

Any store with conditional writes works: S3 `If-Match` / `If-None-Match`, WebDAV ETags,
CloudKit record change tags, or a small REST service. The server never needs to parse a
blob.

## Objects

| Object ID | Content | Encrypted |
|---|---|---|
| `vault-header` | `VaultHeader` JSON: vault ID, KDF params, salt, wrapped VMK | no, it contains nothing secret, and a new device needs it to derive the key |
| `HMAC(objectIDKey, "index")` | envelope → profile index | yes |
| `HMAC(objectIDKey, "profile/<uuid>/config")` | envelope → the profile's `config.bin` bytes | yes (twice) |
| `HMAC(objectIDKey, "profile/<uuid>/passwords")` | envelope → the profile's `passwords.bin` bytes | yes (twice) |

WebKit data archives are **not** synced. They are large and only consistent while the
profile is stopped. Supporting them means adding an object type that carries
`webdata.pbsa`.

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
bound), settings, proxy credentials, passwords, or URLs.

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
   - both changed → call the resolver (default `keepRemote`; the local copy is kept as
     `<file>.conflict`)
4. Delete local directories of profiles removed from the index, and report their IDs so
   the app also removes their WebKit stores.

A lost CAS race leaves the object in `report.deferred`; the next sync retries it.

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
  disk, not live sessions. The app enforces this.
