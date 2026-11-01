// Docs: “The vault and the master password”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-vault.md.
export default {
  title: 'The vault and the master password',
  lead: 'What {{name}} encrypts and how, how to unlock and lock the vault and change the master password — and what to do if you’ve forgotten it.',
  toc: [['contents', 'What the vault holds'], ['keys', 'How the data is encrypted'], ['lock', 'Unlocking and locking'], ['change', 'Changing the master password'], ['forgot', 'If you forgot the master password'], ['sync', 'What a sync location sees']],
  body: `## What the vault holds {#contents}

The vault is a folder named \`PrivacyBrowser\` in your account’s Application Support: \`~/Library/Containers/…/Data/Library/Application Support/PrivacyBrowser\` in a build with the App Sandbox, \`~/Library/Application Support/PrivacyBrowser\` without it. **Settings → About → Build** shows which build you have.

Everything the app writes about profiles is encrypted in it:
- the profile list and each profile’s settings, with its proxy and the proxy’s login, tags and notes;
- saved passwords, history and bookmarks;
- synced cookies and cookies imported before a launch, warm-up plans and schedules, open tabs if restoring them is on;
- the website data archive — cookies, localStorage, IndexedDB, cache — and the state of the profile’s Safari window;
- the proxy list and this Mac’s sync settings.

Outside it, unencrypted: downloaded files; your choices in **Settings** (ordinary app preferences, nothing secret); and files you export — [cookies](docs-cookies.html) and the proxy list in plain text, a profile under its file’s own password.

## How the data is encrypted {#keys}

The master password isn’t stored. At each unlock, Argon2id (RFC 9106: 64 MiB of memory, 3 passes, 4 lanes) derives a key from it and a random 16-byte salt. That key opens only the vault key.

| Key | What it encrypts |
|---|---|
| The vault key: random, 256-bit | The profile list, the profile keys, the proxy list, this Mac’s settings, sync |
| A profile key: random, 256-bit, one per profile | The profile’s files: settings, passwords, history, bookmarks, cookies, website data |

Each kind of file uses its own key — one of these two, or one derived from them — and the cipher is AES-256-GCM throughout. Every encrypted file is bound to its purpose and owner, so moved elsewhere it won’t decrypt. A profile running in a process of its own gets only its own key, never the vault key.

Website data is decrypted on disk only while its profile runs, and is archived, encrypted, when it stops. After a crash, whatever was left decrypted is encrypted at the next unlock.

::: warn
The vault header, \`vault.json\`, is plain text: the salt, the Argon2id parameters and the encrypted vault key. Nothing in it is secret, but whoever has it can guess passwords offline, slowed only by Argon2id’s cost; a short or common password won’t stand up to that.
:::

## Unlocking and locking {#lock}

At launch {{name}} shows **Vault locked**: “Enter your master password to continue.” Type it and click **Unlock**; the **Profiles** window opens. Whether the profiles open at your last quit start too is up to **Settings → Startup → After unlocking**.

A wrong password brings an **Error** alert saying “Wrong master password”, and under the field the app shows when the vault was created and where it is — another build of the app has its own vault and password.

**Lock**, at the bottom of the **Profiles** window’s sidebar and in ⌘K, stops every profile, encrypts their data and forgets the keys. Quitting (⌘Q) does the same and waits for every profile. There’s no automatic lock — no timer, nothing when the Mac sleeps.

Even with the vault open, the app asks for the master password before showing saved passwords (**Passwords are locked**) and before changing it.

## Changing the master password {#change}

1. In the **Profiles** window, open the **⋯** menu (**More**) and choose **Change Master Password…**
2. Fill in **Current password**, **New password** and **Repeat new password**.
3. Click **Change** — available once the new password has at least 10 characters and both new fields match.

Only the key that opens the vault is encrypted anew with the new password; your data and its keys stay as they are. The new password goes to the sync location, so new devices join with it.

It does not reach copies made before: an earlier copy of \`vault.json\` (a backup, Time Machine, a Mac that already syncs) still opens the vault with the old password, including what you save after the change.

::: warn
If such a copy may be in someone else's hands, changing the password is not enough: move your profiles to a new vault (export each profile, create a new vault, import them; an import encrypts everything under new keys).
:::

If it can't be sent to the sync location, the app says: “The new master password is set on this Mac. It could not be sent to the sync location now (…): it goes there at the next sync. Until then, new devices join with the old one.”

If the sync location keeps another Mac's password: “The new master password is set on this Mac, but the sync location keeps another Mac's, changed there later or at the same time: new devices join with that one.”

## If you forgot the master password {#forgot}

It can’t be recovered: the vault key is encrypted with the password alone. But nothing gets deleted.

1. After a wrong password, click **Forgot password…** on the unlock screen.
2. To **Create a new vault?**, answer **Set this vault aside and create a new one**.
3. The folder is renamed \`PrivacyBrowser-backup-\` followed by the date and time; **Create a master password** shows where it went.
4. Create a new, empty vault.

Its profiles stay encrypted with the old password; if that comes back to you, quit the app and rename the folder back to \`PrivacyBrowser\` — after renaming the new vault, which has that name by then.

## What a sync location sees {#sync}

Sync is off until you choose **Folder (local-only)** or **Server** in **⋯ → Sync…**.

A sync location sees the vault header in plain text, there so another Mac can open the vault with the same password (the app can’t yet set up a second Mac like this); how many objects there are, their sizes, versions and when they change; and, for a server, this Mac’s IP address — sync goes directly, not through a profile’s proxy.

The profile list, settings, passwords, bookmarks, history and persistent cookies arrive encrypted (the profiles’ files twice) under opaque names: no profile names, site addresses, proxies, passwords or cookies are visible. Other website data doesn’t sync.

The {{name}} server doesn’t keep the IP address: it is used only in memory, to limit request rates. Nor does it keep which Mac synced when — only when the vault last changed. What it sees is on the [Sync page of your account](account-sync.html).`,
};
