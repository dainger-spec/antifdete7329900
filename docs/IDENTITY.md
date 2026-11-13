# The app's identity: Lumen

The product is **Lumen**. Before its first release it was renamed from a placeholder; this is
what changed, what kept the old name and why, and what has to be registered with Apple.

## Names

| What | Name |
|---|---|
| The app, as a person sees it | `Lumen.app`; `CFBundleName` and `CFBundleDisplayName` Lumen |
| Bundle ID (`scripts/build-app.sh`, `BUNDLE_ID`) | `io.lumenbrowser.Lumen` |
| The executable, `Contents/MacOS/` | `Lumen` — the SwiftPM product `PrivacyBrowser`, renamed when the bundle is made |
| A profile's process | `Contents/MacOS/LumenProfile` — the same code, signed apart under the same identifier without the entitlements that give a keychain (`ProfileExecutable`; "The keychain" below) |
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
Lumen. An import does not take three of the file's settings — the proxy's bypass list, Safe
Browsing, and local requests allowed (`ProfileTransfer.LeftOut`, the security audit's APP-08: a file
is often someone else's, and each sends something around the proxy); the import window names those
it leaves out, and they are set again in the profile's editor.

**The keychain.** The app's code keeps nothing in a keychain, and a profile's process must neither
keep anything in one nor be shown anything of one, whatever the app's signature holds. There are two
to reach. The data-protection keychain opens to an application identifier, an access group or an app
group: a build with the network extension (`NE=1`) gives the app `<TEAM_ID>.io.lumenbrowser.Lumen`
and the app group, and Safari's code in a process holding them would keep its "Safari Defaults"
there, under that identifier and shared by every profile. The account's login keychain, the
file-based one, opens to any process of the account that securityd answers, whatever its signature:
opening it by its path, as any code in it can, a profile's process kept an item there that every
other profile's process was shown, as it was shown an item the app made under its own signature (CI
run 659, both macOS). That keychain shows any process the attributes of every item in it — names of
services and accounts, never a secret — so the person's own were open to it the same way; the check
asks only for its own service and does not look at them. Asked for "the default keychain" instead, a
profile's process — whose home is its own and holds none — was left waiting on the system's dialog
(run 656).

Closed (3 November) by the profile's own sandbox, whatever its signature holds: every profile's
process puts itself in a kernel sandbox before Safari's frameworks load
(`ProfileNetworkGuard.closeTheProcess`), which refuses securityd's services — `com.apple.SecurityServer`,
the login keychain's, and every `com.apple.securityd.*`, the data-protection keychain's (secd) — and
the account's `~/Library/Keychains`, read or written. The process then looks the two services up
itself; if either still answers, the profile does not run. The app's own process is not in that
sandbox: outside profiles its keychain is as it was.

And by the profile's executable (2 November): every profile's process — and every process that runs
Safari's code for the app — is started from `Contents/MacOS/LumenProfile`, the same code signed with
the base entitlements only (`scripts/build-app.sh`: none of `com.apple.application-identifier`,
`keychain-access-groups`, `com.apple.security.application-groups`,
`com.apple.developer.team-identifier`, nor the network guard's, read back from the signature after
signing). The app reads LumenProfile's signature before every start and starts nothing from it, or
from anything else, when it carries one of them (`ProfileExecutable`): a profile does not open, and
the person is told the copy of Lumen is damaged. LumenProfile keeps the app's identifier, by which
the network guard knows a profile's process (anchor, identifier, team).

Shown by the self-test and by the release check on the build that ships (`KeychainIsolation`), in
three verdicts:

1. A profile's process holds none of those entitlements; the app's own executable does (CI's
   `NE=check` build gives the app the app group, the one an ad hoc signature can carry).
2. The login keychain: profile A keeps nothing there and profile B is shown nothing of it, while two
   processes of the profile's executable outside a profile's sandbox keep an item and see it (the
   control) and the app keeps and sees its own. Without the sandbox's lock this verdict fails (CI run
   659: profile A kept an item there and profile B was shown it, and the app's); with it, it passes
   (run 660: securityd refused to both profiles, nothing kept, nothing shown).
3. The data-protection keychain: on a build signed by the team, profile A's item is refused and
   profile B sees neither it nor the app's, which a process of the app's own executable does see. On
   CI's runners no ad hoc signature opens that keychain, the app group included (run 646), so this
   one is shown only on a signed build.

A release whose app holds the team's identity stops if any of the three is not shown, and
`release.sh` reads every line of the check (`scripts/release_check_gate.sh`). CI also makes the
release's app with LumenProfile signed with the app group: it must not start a profile.

**On a build the team signed (3 November).** 0.1.1 with the network guard (`NE=1`), signed with
Developer ID and notarized, on the owner's Mac (macOS 27.0.1, build 26A434, J713): the kernel's
log shows a profile's process refused both of securityd's services by its sandbox —
`denied lookup: com.apple.SecurityServer` and `denied lookup: com.apple.securityd.xpc`, a Sandbox
restriction — in a build whose bundle carries the network guard's rights. The lock behind verdicts 2
and 3 is so shown on the real signature, not only on CI's ad hoc one. The release check's own three
verdicts on that build were not reached: its app's executable was killed by the kernel at its start
(docs/TUNNEL.md, "Status"). They were on its copy `app-no-dlv` the same day — the app's executable
signed again with Developer ID without library validation off, the layout every build has since
(docs/TUNNEL.md, "What the kernel kills"): profiles A and B `refused (1100)` by both securityd
services, the control outside a profile's sandbox wrote its item and read it back.

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
