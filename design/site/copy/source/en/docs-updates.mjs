// Docs: “Updates”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-updates.md.
export default {
  title: 'Updates',
  lead: 'How {{name}} finds, checks and installs new versions, what you see, and what the update server learns.',
  toc: [['find', 'How updates are found'], ['screen', 'The Updates section'], ['check', 'How an update is checked'], ['install', 'When an update is installed'], ['after', 'What is kept, and how rollback works'], ['server', 'What the update server sees'], ['notes', 'Release notes'], ['missing', 'What isn’t there yet']],
  body: `## How updates are found {#find}

Updates are in **Settings** (⌘,) → **Updates**, or ⌘K → **Settings: Updates**; there’s no menu item for checking.

Only a release build, carrying the feed’s address and signing keys, asks for updates; any other says: “This build has no update feed, so it never asks for updates. Release builds have one.”

::: unv
No release with an update feed has been published yet, and no update server named; the first release that updates itself from a real server will confirm it.
:::

Automatic checks are on by default: the first no sooner than a minute after launch, then every 6 hours. **Check Now** asks the feed, a static list of releases, at once. With **Check for updates automatically** off, nothing is asked.

## The Updates section {#screen}

Besides **Version** and a status line, it has **When an update is found**: **Download it, install when I quit** (the default) or **Only tell me**, which shows “Version … is available.” and **Download**; either way, a downloaded update installs at quit.

| What it says | What it means |
|---|---|
| Up to date (checked …). | Nothing newer |
| Version … is downloaded and checked. It installs when you quit, once every profile is encrypted. | **Install Now…** appears |
| The last check failed: … | Feed or archive not received, or a check failed |
| …macOS runs this copy from a temporary place… | Move {{name}} to Applications, then check again |
| …you cannot replace the app where it is… | Your account can’t write to the app’s folder |

## How an update is checked {#check}

An update is the whole app in a zip archive, checked at every step:
1. The feed is signed with Ed25519 and isn’t read until the signature checks with a key built into the app; a feed older than one already accepted is refused.
2. Only a release newer than yours and made for your macOS is taken — never an older one.
3. The archive’s size, SHA-256 and Ed25519 signature must match the feed.
4. After you quit, the installer inside the app checks the archive again, then the new app’s code signature (strictly, nested code included), identifier and version. If the build is signed with an Apple developer certificate, the new version must come from the same developer {{unv:whether releases are signed with an Apple developer certificate}}. Only then is the quarantine flag cleared.

## When an update is installed {#install}

Only at a quit you started — ⌘Q, the menu or the Dock — once every profile is stopped and encrypted. The app first checks that nothing runs, starts or is being encrypted; that no profile’s process had to be stopped by force (the quit waits 30 seconds for one); and that no profile’s data lies unencrypted on disk. If anything fails, the update waits for the next quit, and the next launch says why. Never at a logout, restart or shutdown, or after a crash.

**Install Now…** does this on request: its alert lists what will stop, and **Stop, Encrypt and Install** (or **Quit and Install** when nothing runs) goes ahead. If the check fails, the app stays open, locked, and says why.

The installer then waits for the app’s processes to end — stopping none, backing off after 10 minutes until the next quit — swaps the old and new app in one step and starts the new one.

## What is kept, and how rollback works {#after}

An update replaces only the app: [the vault](docs-vault.html) and your settings stay in your account’s Library folder. An older version installed by hand won’t read or change files a newer one wrote: “The file … was saved by a newer version of {{name}}…”

If the new app fails its check in place or doesn’t start, the installer restores and starts the previous one, and the next launch says: “Update … was installed but did not start, so the previous version is back.” If even that fails, the previous version stays beside it as “… (previous version)”. There’s no command to go back a version; after a successful update the section says “Updated to … (…).”

## What the update server sees {#server}

Under the setting, the app says: “The update server sees this Mac’s IP address, when it asks, and which update it downloads. Nothing else is sent: no identifier, no profile, no proxy. The check never goes through a profile’s proxy.”

The request carries no parameters, cookies or cache, and the same headers from every Mac: a User-Agent without a version, and the language \`en\`. No licence check is tied to it — the app has none.

## Release notes {#notes}

**What’s new in …** shows the feed’s notes as plain text, not as a web page; without notes, “This release has no notes.”

Notes for the next release are written; both changes concern the build without the App Sandbox (Safari’s window):
- settings for Safari’s services that earlier versions wrote into your account’s Safari settings file (which Safari doesn’t read) are removed once, after the first unlock — only values {{name}} wrote that nobody changed;
- each profile’s Safari window keeps its own layout (size and place, sidebar, favorites bar, start page sections) in the profile’s encrypted data; after the update, each profile opens once with Safari’s default layout.

## What isn’t there yet {#missing}

- Installing where only an administrator can write: the app says it can’t install there.
- Partial updates: every update is a whole signed archive.
- Updating the system extension for WebRTC through proxies by this path.`,
};
