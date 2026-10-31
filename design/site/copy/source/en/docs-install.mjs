// Docs: “Installing and the first launch”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-install.md.
export default {
  title: 'Installing and the first launch',
  lead: 'How to put {{name}} on your Mac, create the vault with a master password, and get to your first profile.',
  toc: [['download', 'What you need and what you download'], ['install', 'Installing'], ['setup', 'The first screen: the master password'], ['after', 'What happens next'], ['first-profile', 'Your first profile'], ['next', 'Later launches']],
  body: `## What you need and what you download {#download}

{{name}} runs on Macs with Apple Silicon and macOS 26 or later. Intel Macs aren’t supported.

You download one app. It creates the vault for its data on the first launch.

::: unv
In what form the app comes on the download page — a disk image or a zip archive — and what its file is called isn’t confirmed yet: the release script packs the app into a zip archive today, and a disk image is only planned. The first published release will confirm it.
:::

## Installing {#install}

1. Move {{name}} to the Applications folder.
2. Open it from there.

The folder matters for updates. If macOS runs the app from a temporary place or from a read-only disk, or if your user account can’t write to the app’s folder, an update can’t be installed — the **Updates** section of Settings says so. More in [Updates](docs-updates.html).

{{name}} keeps its data in your user account’s Library folder, not next to the app. Moving or replacing the app doesn’t touch it.

::: unv
What macOS shows the first time you open a downloaded copy isn’t confirmed: releases aren’t signed with an Apple developer certificate or notarized by Apple yet. A notarized build opened on a Mac that has never run it will confirm it.
:::

::: unv
How to choose the interface language. Today {{name}}’s windows are in Russian whatever language macOS uses, and the app has no language switch: the English interface — whose labels this article uses — turns on only with an environment variable meant for development. English at launch is the owner’s decision; a language switch in the app will confirm it.
:::

## The first screen: the master password {#setup}

On the first launch you see **Create a master password**. Under the title the app explains: “The master password encrypts the profile list, every profile’s settings, saved passwords, history, bookmarks and archived website data. It cannot be recovered — if you forget it, the data is lost.”

1. Type a password into **Master password**.
2. Type it again into **Repeat master password**.
3. Click **Create Vault**, or press Return.

The rules are simple: at least 10 characters, and both fields the same. Once you start typing, a hint appears under the fields — **Use at least 10 characters.** or **Passwords do not match.** Until both rules are met, the button can’t be clicked. There are no rules about letters, digits or symbols.

::: warn
The master password can’t be recovered or reset. Write it down somewhere you won’t lose it. If you do forget it, see [The vault and the master password](docs-vault.html).
:::

## What happens next {#after}

The form gives way to a progress line and **Creating the vault…** while the key is derived from the password. {{name}} sets up the vault: a folder on this Mac in which the profiles’ data is kept encrypted. How that works: [The vault and the master password](docs-vault.html).

Then the **Profiles** window opens:
- on the left, **All Profiles**, **Running**, **Proxies**, and the filters **Through a Proxy** and **Ephemeral**; at the bottom, the sync state (**Sync is off**) and the **Lock** button;
- at the top, the **Search** field, the **⋯** menu and the **New Profile** button;
- in the middle, while there are no profiles, **No profiles yet** and the hint “Create your first isolated profile to start browsing.”

⌘, opens the **Settings** window.

## Your first profile {#first-profile}

1. Click **New Profile** (⌘N). The **New Profile** editor opens, subtitled “Its own cookies, identity and network”.
2. Give the profile a name, add a proxy if you need one, and click **Save**.
3. The profile appears in the list. **Launch** opens its window.

Everything in the editor is in [Creating a profile](docs-profile.html); proxies are in [Proxies: setup, and when one fails](docs-proxy.html).

## Later launches {#next}

From then on, each launch shows **Vault locked**. Type the master password and click **Unlock**.

The vault stays open until you click **Lock** or quit the app (⌘Q). Either way, every profile stops and its data is encrypted.`,
};
