# Sync server API (v1)

This is the HTTP contract `HTTPSyncTransport` speaks
(`Sources/BrowserCore/Sync/Transports/HTTPSyncTransport.swift`). **No server is included.**
The client is tested against an in-process stub that implements exactly these semantics
(`Tests/BrowserCoreTests/SyncImprovementTests.swift`, `StubSyncServer`).

The server is a dumb blob store. Every blob it receives is already end-to-end encrypted,
except `vault-header`, which holds only the KDF salt, the KDF parameters and the wrapped
vault key (see [SYNC_FORMAT.md](SYNC_FORMAT.md)). The server needs no crypto and never sees
plaintext.

A server and its account page are built to the decisions accepted in
[SYNC_FORMAT.md](SYNC_FORMAT.md#accepted-decisions-for-a-server-october-2026): sync goes directly,
not through a profile's proxy; one batched connection per app, never one per profile on a timer,
and a lease taken during a sync instead of a live lock; ciphertext only, with nothing on the
account page that needs to read content; off by default, behind an honest screen; and the logs the
server keeps decided explicitly before it runs.

## Conventions

- Base URL: configured by the user, e.g. `https://sync.example.com/api`. All paths below
  are relative to it. **HTTPS is required.** The client refuses `http://`, except for
  `localhost` when `allowInsecureLocalhost` is set for development.
- `{vault}`: the vault UUID, in lowercase.
- `{object}`: either `vault-header` or 64 lowercase hex characters. The server should reject
  anything else with `400`.
- Auth: `Authorization: Bearer <token>`. How tokens are issued and how vaults map to
  accounts is up to the server. Answer `401` or `403` when the token is missing or wrong.
- Revisions are positive integers, chosen by the client. A write must carry a revision
  higher than the current one.

## Endpoints

### List objects

```
GET /v1/vaults/{vault}/objects
→ 200  {"objects": [{"id": "<object>", "revision": 7}, …]}
```

An empty or unknown vault returns `200` with `{"objects": []}`.

### Fetch an object

```
GET /v1/vaults/{vault}/objects/{object}
→ 200  body = blob (application/octet-stream),  ETag: "<revision>"
→ 404  object does not exist
```

### Store an object (compare-and-swap)

```
PUT /v1/vaults/{vault}/objects/{object}
Content-Type: application/octet-stream
X-PB-Revision: <new revision>
If-Match: "<expected current revision>"     — update an existing object
If-None-Match: *                            — create; the object must not exist
body = blob
→ 201 / 200 / 204   stored;  ETag: "<new revision>"
→ 412               precondition failed (someone else wrote first);  ETag: "<current revision>"
→ 400               bad object ID, missing/non-increasing X-PB-Revision
→ 428               neither If-Match nor If-None-Match present
→ 413               blob too large (server-defined limit)
```

The check of the precondition and the write must be atomic, for example as a single
conditional UPDATE in a database. `412` is not an error for the client: the engine reports
the object as `deferred` and retries it on the next sync, after merging where the object
type allows it.

## Limits and expectations

| Item | Typical size |
|---|---|
| `vault-header` | < 1 KB |
| profile index | ~1 KB per profile |
| config / passwords / bookmarks | a few KB each |
| history | up to ~2 MB per profile (10 000 entries) |

A server should accept blobs of at least 8 MB.

## Rollback

Revisions are monotonic per object, but the client cannot tell whether the server serves
an old *set* of objects. A server that also wants to be auditable could add a signed,
append-only log of `(object, revision, sha256(blob))`. That is not part of v1.

## What is ready vs. what is not

| Part | Status |
|---|---|
| Wire format (envelope, object IDs, AAD binding) | ready, stable (`pbsync-1`) |
| Client engine (merge, CAS, deferral, tombstones) | ready, unit-tested |
| HTTP client for this API | ready, tested against an in-process stub |
| Folder transport | ready, **local-only** (NAS share, external disk) |
| Server implementation | **not included** |
| Accounts, token issuance, vault sharing between users | **not designed** |
| Push notifications / live sync | not designed; the client syncs on demand |
