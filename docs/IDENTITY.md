# The app's identity: Lumen

The product is **Lumen**. Before its first release it was renamed from a placeholder; this is
what changed, what kept the old name and why, and what has to be registered with Apple.

## Names

| What | Name |
|---|---|
| The app, as a person sees it | `Lumen.app`; `CFBundleName` and `CFBundleDisplayName` Lumen |
| Bundle ID (`scripts/build-app.sh`, `BUNDLE_ID`) | `io.lumenbrowser.Lumen` |
| The executable, `Contents/MacOS/` | `Lumen` — the SwiftPM product `PrivacyBrowser`, renamed when the bundle is made |
| The installer helper | `Contents/Helpers/Lumen Updater.app`, executable `LumenUpdater`, bundle ID `io.lumenbrowser.Lumen.Updater` |
| The network guard's system extension (a content filter, docs/TUNNEL.md) | `io.lumenbrowser.Lumen.PacketTunnel` (`EXTENSION_ID`: the App ID registered on 31 October, kept), shown as "Lumen network guard" |
| The app group (NE builds only) | `<TEAM_ID>.io.lumenbrowser.Lumen` (`APP_GROUP`); the extension's Mach service `<TEAM_ID>.io.lumenbrowser.Lumen.guard` |
| Releases | `Lumen-<version>.zip` (`scripts/release.sh`) |

Every text of the app's own that names the product says Lumen (both languages), and so do the
diagnostics archive (`Lumen-Diagnostics-….zip`), exported cookie and proxy files, and the update
check's `User-Agent`.

## Kept as they were, on purpose

- **The code**: the Swift package, its targets, products, modules and types (`PrivacyBrowser`,
  `PrivacyBrowserUpdater`, `PrivacyBrowserApp`…), the entitlements' file names, the environment
  variables (`PRIVACYBROWSER_VAULT_DIR`, `PRIVACYBROWSER_LANG`).
- **The vault's folder**, `~/Library/Application Support/PrivacyBrowser` (in the container
  `…/Data/Library/Application Support/PrivacyBrowser`). The profiles' homes are inside it, and
  homes nested by builds before 1 November (`…/home.noindex/Library/Application Support/
  PrivacyBrowser/profiles/<id>/home.noindex/…`) are brought back at a profile's launch by finding
  the nested levels by the home's own path (`SafariHomeVault.flattenNested`): renamed, the folder
  would no longer match the levels those builds made, and the Safari databases in them would stay
  out of sight. Nor can anything that Safari's code may keep in a home's files as a whole path be
  shown to follow a moved folder. Kept, the folder needs nothing: an unsandboxed Lumen finds every
  existing vault where it is. The setup screen's text that names the folder names it as it is.
- **Inside a profile's home**, `Library/PrivacyBrowser/SafariDefaults` (Safari's per-profile
  settings): a path in sealed data, for the same reason.
- **The log's subsystem**, `PrivacyBrowser` (and the extension's `PrivacyBrowser.NetworkGuard`): the
  bundle ID is a build setting (CI builds four of them), the readers of the log — the diagnostics
  archive, the exception log's reader, CI's update check — would have to move with it in step, and
  the extension's code is not changed by the rename.
- **The content worlds' and queues' labels** (`PrivacyBrowser.Passwords`, `PrivacyBrowser.WarmUp`…):
  no person or page sees them.

## What an existing installation finds

**Without the App Sandbox (the build whose profiles open in Safari's window).** The vault is where
it was; Lumen opens it with the same password, and every profile with it. A profile's website data
— sealed in the vault under labels that carry the bundle ID that sealed it — is restored under
Lumen's (`WebKitDataLayout` drops the bundle ID of a label and puts in its own; CI's step "The
product renamed" opens a vault the last build named PrivacyBrowser wrote and reads its profile's
cookie, localStorage and IndexedDB back through WebKit). Safari's state of a profile is in the
profile's home, in the vault: unchanged.

What is tied to the old bundle ID, and stays behind:

- the Settings window's choices (startup, quit confirmation, downloads folder, page zoom, restoring
  tabs, new profiles' defaults) and the interface language: they are kept in the app's own
  preferences, `~/Library/Preferences/<bundle ID>.plist`, so Lumen starts with the defaults;
- WebKit data a crash left unsealed under the old bundle ID (`~/Library/WebKit/dev.local.PrivacyBrowser/…`):
  Lumen does not look there. The old build seals it at its next unlock — so open the old build once,
  unlock and quit, before the switch;
- the old build's own folders: `~/Library/WebKit/dev.local.PrivacyBrowser`,
  `~/Library/Caches/dev.local.PrivacyBrowser`, `~/Library/HTTPStorages/dev.local.PrivacyBrowser`,
  `~/Library/Caches/dev.local.PrivacyBrowser.update`, `~/Library/Saved Application State/dev.local.PrivacyBrowser.savedState`;
- macOS's permissions (camera, microphone, local network) and the default-browser choice: asked for
  again, by Lumen;
- updates: an old build does not update itself into Lumen (the installer takes only the same bundle
  ID); Lumen.app is put in Applications by hand, and PrivacyBrowser.app removed.

**With the App Sandbox.** A sandboxed build keeps everything in its container, which macOS names
after the bundle ID: `~/Library/Containers/dev.local.PrivacyBrowser`. Lumen, sandboxed or not, does
not open it: its profiles stay there, for the old build. To carry one, export it there (its row in
the Profiles window → Export Profile…, a `.pbprofile` with a password of its own) and import it in
Lumen.

**The keychain.** Nothing to lose: the app's code keeps nothing in a keychain, and every keychain
write a profile's process makes is refused for want of an entitlement (`errSecMissingEntitlement`,
CI run 521; CI's keychain measurement lists what appears while the app runs). A build with the
network extension (`NE=1`) carries the application identifier `<TEAM_ID>.io.lumenbrowser.Lumen`,
which opens the data-protection keychain to it: Safari's code in a profile's process would then keep
its "Safari Defaults" there, under that identifier and shared by every profile — to be closed before
an NE build ships.

## What to register with Apple

In this order, in Certificates, Identifiers & Profiles of the team that signs Lumen:

1. **Certificate, Developer ID Application** (made by the account holder, from a certificate signing
   request of the Mac that will sign). It signs the app, its helper and the extension; notarization
   takes only this. *Developer ID Installer* only for a `.pkg`.
2. **Identifier, App ID (explicit, macOS) `io.lumenbrowser.Lumen`**, description "Lumen":
   capabilities *Network Extensions*, *System Extension* and *App Groups* (on, nothing assigned).
3. **Identifier, App ID (explicit, macOS) `io.lumenbrowser.Lumen.PacketTunnel`**, description
   "Lumen WebRTC relay": capabilities *Network Extensions* and *App Groups* (on, nothing assigned).
   Since 2 November it holds the network guard, a content filter (docs/TUNNEL.md): the same App ID
   and capability; its profile must allow `content-filter-provider-systemextension`, which the
   Network Extensions capability grants with the others.
4. **The app group `<TEAM_ID>.io.lumenbrowser.Lumen`: nothing to register.** A macOS group named with
   the team ID's prefix is the team's by its signature; the portal's App Groups list holds `group.…`
   identifiers only. This is the step least sure to hold as written: if the extension is refused for
   its group, the other way is `group.io.lumenbrowser.Lumen`, registered there, assigned to both App
   IDs, the profiles made again, and given as `APP_GROUP`.
5. **Profiles, Developer ID**: one for `io.lumenbrowser.Lumen` (→ `APP_PROFILE`), one for
   `io.lumenbrowser.Lumen.PacketTunnel` (→ `EXTENSION_PROFILE`), both with the certificate of 1.
   For a test on one registered Mac first: *macOS App Development* profiles for the same two App IDs,
   that Mac in Devices, an *Apple Development* certificate and `NE_SIGNING=development`.
6. **Notarization**: an app-specific password of the Apple Account (account.apple.com), kept in
   the keychain once: `xcrun notarytool store-credentials lumen-notary --apple-id … --team-id <TEAM_ID>`;
   then `NOTARY_PROFILE=lumen-notary`.

The helper `io.lumenbrowser.Lumen.Updater` has no entitlement that needs a profile: no App ID.
Then (docs/TUNNEL.md, docs/UPDATES.md §6):

```sh
NE=1 TEAM_ID=<TEAM_ID> SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)" \
  APP_PROFILE=lumen.provisionprofile EXTENSION_PROFILE=lumen-guard.provisionprofile \
  NOTARY_PROFILE=lumen-notary VERSION=0.1.0 BUILD=1 UPDATE_KEY_FILE=… FEED_URL=https://… \
  scripts/release.sh
```
