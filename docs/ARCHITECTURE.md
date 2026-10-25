# Architecture

## Engine choice

The browser is built on **WKWebView (system WebKit)**, not Chromium or Electron:

- macOS 14 added the two APIs a multi-profile browser needs: persistent, separately
  identified data stores (`WKWebsiteDataStore(forIdentifier:)`) and per-store proxies
  (`WKWebsiteDataStore.proxyConfigurations`).
- Electron is Chromium-based, so "Electron + WKWebView" isn't a real combination.
  Embedding Chromium (CEF) would give finer engine control, such as Chromium's
  `--force-webrtc-ip-handling-policy` flag, at the cost of shipping and patching a second
  engine. Where WebKit's public API falls short, this project documents the gap and uses
  the closest viable workaround instead of using private API.

No private WebKit API is used. Places where private API would help (custom data store
directories, disabling WebRTC at engine level) are noted in comments and in
[ISOLATION_AND_LIMITATIONS.md](ISOLATION_AND_LIMITATIONS.md).

## Components

```
┌──────────────────────────── PrivacyBrowser (macOS app) ────────────────────────────┐
│  SwiftUI: SetupView / UnlockView / ProfileListView / ProfileEditorView / Passwords │
│        │                                                                           │
│  AppModel ── lock state, vault, errors                                             │
│        │                                                                           │
│  ProfileManager ── launch / stop / delete / crash recovery                         │
│        ├── WebDataStoreVault ── seal/unseal WebKit dirs  (EncryptedDirectoryArchive)│
│        └── BrowserSession (one per running profile)                                │
│              ├── WKWebsiteDataStore(forIdentifier:)  + proxyConfigurations          │
│              ├── WKUserContentController + PrivacyScripts (TZ / geo / WebRTC)      │
│              └── BrowserWindowController × n  (WKWebView, popups, auth, downloads)  │
└────────────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────── BrowserCore (platform-independent) ────────────────────┐
│  MasterVault / UnlockedVault ── PBKDF2, key hierarchy                              │
│  ProfileRepository ── encrypted index + per-profile config                         │
│  PasswordVault ── per-profile encrypted credentials                                │
│  EncryptedChunkStream / EncryptedDirectoryArchive ── streaming AEAD archives       │
│  SyncCodec / SyncEngine / SyncTransport ── encrypted sync client                   │
└────────────────────────────────────────────────────────────────────────────────────┘
```

`BrowserCore` has no dependency on AppKit or WebKit. It builds on Linux with
swift-crypto, which lets CI run the crypto and storage tests without a Mac.

## Key hierarchy

```
master password
   │ PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte random salt
   ▼
KEK (key-encryption key, never stored)
   │ AES-256-GCM unwrap  (vault.json: wrappedMasterKey, AAD "vault-master-key:v1:<vaultID>")
   ▼
VMK (vault master key, random 256-bit)
   ├─ HKDF "profile-index"     → encrypts index.bin           (profile names, wrapped profile keys)
   ├─ HKDF "profile-key-wrap"  → wraps each profile key        (AAD "profile-key:v1:<uuid>")
   ├─ HKDF "sync-envelope"     → encrypts sync envelopes + sync-state.bin
   └─ HKDF "sync-object-id"    → HMAC key for opaque sync object IDs

profile key (random 256-bit per profile, stored only wrapped)
   ├─ directly                 → config.bin                    (AAD "profile-config:v1:<uuid>")
   ├─ HKDF "passwords"         → passwords.bin                 (AAD "passwords:v1:<uuid>")
   └─ HKDF "webdata-archive", salt = random per archive → webdata.pbsa chunk key
```

All HKDF derivations use the vault ID (or profile ID) as salt. Every ciphertext's AAD
names its purpose and owner, so moving a ciphertext into another file or profile makes
decryption fail.

Changing the master password re-wraps only the VMK. A new device unlocks with the same
password because `vault.json` (salt, KDF parameters and wrapped VMK) is synced in
plaintext.

## On-disk layout

```
~/Library/Application Support/PrivacyBrowser/      (0700)
  vault.json                      plaintext: format, vaultID, KDF params, wrapped VMK
  index.bin                       AES-GCM(index key, ProfileIndex JSON)
  sync-state.bin                  AES-GCM(sync key, per-object revision + hash)   [only after sync]
  profiles/<uuid>/
    config.bin                    AES-GCM(profile key, ProfileConfiguration JSON)
    passwords.bin                 AES-GCM(password key, [PasswordEntry] JSON)
    webdata.pbsa                  streaming encrypted archive of WebKit's data dirs

~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid>/            ┐ WebKit-owned; exist only
~/Library/Caches/<bundle-id>/WebKit/WebsiteDataStore/<uuid>/     ┘ while the profile runs
```

Every file is written with mode 0600 through a temp file and `rename(2)`, so a crash
never leaves a half-written ciphertext.

### `webdata.pbsa` format

```
header  = "PBSA" | version u8 | chunkSize u32 | salt[32]
chunk*  = len u32 | ciphertext | tag[16]
key     = HKDF-SHA256(profileKey, salt, "webdata-archive")
nonce_i = 0x00000000 || u64(i)            AAD_i = header || u64(i) || final u8
```

The plaintext is a record stream (`kind | path | mode | [size | bytes]`). Files are
streamed in 1 MiB chunks, so memory use stays bounded. Readers reject truncation, data
after the final chunk, reordered chunks, unsafe paths (`..`, absolute, NUL) and symlinks.
Extraction goes to a staging directory, and nothing reaches its destination until the
whole archive has authenticated.

## Profile lifecycle

```
            ┌────────────── unlock (master password) ──────────────┐
            │ index decrypted → names visible; configs still sealed │
            └───────────────────────────┬───────────────────────────┘
                                        │ crash recovery: any WebKit dir named <uuid>
                                        │ of a non-running profile is sealed now
              launch                    ▼                     stop / last window closed / lock / quit
  ┌───────────────────────────────────────────┐      ┌──────────────────────────────────────────────┐
  │ unwrap profile key                        │      │ close windows, tear down web views           │
  │ decrypt config.bin, open PasswordVault    │      │ drop WKWebsiteDataStore reference            │
  │ unseal webdata.pbsa → WebKit dirs         │ ───▶ │ wait → archive+encrypt dirs → webdata.pbsa   │
  │ WKWebsiteDataStore(forIdentifier: uuid)   │      │ WKWebsiteDataStore.remove(forIdentifier:)    │
  │   .proxyConfigurations = [proxy]          │      │   (fails while in use → retry with backoff)  │
  │ user scripts (TZ / geo / WebRTC)          │      │ sweep leftovers, drop profile key            │
  │ window → start URL                        │      └──────────────────────────────────────────────┘
  └───────────────────────────────────────────┘
```

Ephemeral profiles skip the seal/unseal steps because `nonPersistent()` stores write
nothing to disk.

The app delays termination (`applicationShouldTerminate` → `.terminateLater`) until
every running profile is sealed.

## Concurrency

- UI, `ProfileManager`, `BrowserSession`, window controllers and `WebDataStoreVault` are
  `@MainActor`. That matches WebKit's main-thread requirement.
- PBKDF2 and archive I/O run on detached tasks, so the UI stays responsive.
- `ProfileRepository` and `PasswordVault` serialise mutations with a lock. While a profile
  runs, the manager hands out that session's `PasswordVault` instance, so each file has
  only one writer.
