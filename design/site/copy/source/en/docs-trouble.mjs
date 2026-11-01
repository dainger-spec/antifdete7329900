// Docs: “If something goes wrong”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-trouble.md.
export default {
  title: 'When something fails',
  lead: 'What {{name}} says when a profile, the vault, sync or an update fails, what that means and what to do — and how to put together a report for us.',
  toc: [['table', 'At a glance'], ['start', 'A profile does not start'], ['crash', 'A profile crashed or hangs'], ['app', '{{name}} itself quit'], ['vault', 'The vault does not open'], ['sync', 'Sync failed'], ['updates', 'An update was not installed'], ['report', 'Reporting a problem']],
  body: `## At a glance {#table}

| You see | Do this |
|---|---|
| **“…” loads no pages** or **“…” was not started** | Fix the proxy, then **Check Proxy** |
| “Profile ‘…’ ended unexpectedly” | **Launch** it again |
| A profile’s window does not respond | **Stop** it in the Profiles window |
| “Wrong master password” | Check it; if it is lost, **Forgot password…** |
| **Last sync failed** in the sidebar | Click it: the **Sync** sheet gives the reason |
| **Not imported: …** after a cookie import | [Importing and exporting cookies](docs-cookies.html) |

## A profile does not start {#start}

A profile never goes around its proxy: if the proxy fails, nothing loads, and the Profiles window says why.

- **“…” loads no pages**: the profile started; its proxy does not work. The sheet shows the failed step and what to do. Fix the proxy, click **Check Proxy**, and at “The proxy works now” reload the page.
- **“…” was not started**: the same, when **Settings → Proxies → A proxy that does not work** is **Do not start the profile**.
- **Error** “The proxy at ‘…’ requires a user name and password…” or “The profile's proxy is misconfigured…”: correct the proxy in the profile’s **⋯ → Edit…**.
- “The file … was saved by a newer version of {{name}}…”: install that version.

More: [Proxies: setup, and when one fails](docs-proxy.html).

## A profile crashed or hangs {#crash}

If a profile in its own process (with its own Dock icon) ends unexpectedly, {{name}} brings the Profiles window forward: “Profile ‘…’ ended unexpectedly. Its data is encrypted…” Its next launch keeps sign-ins and cookies, not open tabs. The profile is not restarted: click **Launch**. Other profiles keep running.

::: unv
Untested: that a crash in the middle of a write leaves the profile intact (an open roadmap item).
:::

{{name}} does not watch for hangs, only for a process that ended. Click **Stop**: the profile is asked to close, and if its own process has not closed within 30 seconds, it is ended.

In a {{name}} window a page whose process crashed reloads by itself. {{unv:what Safari’s own window in a profile does then}}

## {{name}} itself quit {#app}

Profiles in {{name}}’s windows go with it; those in their own processes quit too {{unv:whether they encrypt their data on the way out — no test covers it}}. After the next unlock {{name}} encrypts whatever was left unencrypted, or says “Could not encrypt the data of profile ‘…’ again: …”.

The vault comes back as it was: its files are written as a new copy, then swapped in — never half-written. Website data that was on disk, cookies included, comes back too; a crashed profile loses at most the last 3 seconds of history. Profiles that were running do not start again: **And the profiles open at quit** is recorded only when you quit. A crash never installs an update.

## The vault does not open {#vault}

- **Error** “Wrong master password”. The lock screen then shows the folder and creation date of the vault it opened: another build of the app keeps its own.
- Right password, damaged file: the vault stays locked, and **Error** gives the error’s own text, such as “Authentication failed (wrong key or data was modified)”. {{name}} does not repair vaults: send us that text and diagnostics (they work while it is locked). A damaged vault header can also look like a wrong password.
- A lost password cannot be recovered. **Forgot password…** sets the vault aside, deleting nothing, and starts a new one: [The vault and the master password](docs-vault.html).

## Sync failed {#sync}

Sync runs only while no profile does: until then **Sync Now** in **⋯ → Sync…** is off, with “Stop all profiles first.”

A failed sync shows **Error** “Sync failed: …” and **Last sync failed** in the sidebar; click it, and the sheet gives the reason. Fix it and sync again. “…holds a different vault”: the folder belongs to another vault — use one folder per vault.

The status also counts conflicts — the same thing changed on two Macs: newer settings win, and for passwords the other Mac’s copy; the losing version stays on this Mac, encrypted, and is not offered back.

## An update was not installed {#updates}

An update installs only at a quit that encrypted every profile. Otherwise the next launch says “The update was not installed at the last quit: …”; it waits for a later quit. A failed check shows in **Settings → Updates**: “The last check failed: …” — click **Check Now** later. More: [Updates](docs-updates.html).

## Reporting a problem {#report}

1. Press ⌘, and open **Diagnostics**.
2. Click **Collect Diagnostics…** and save the ZIP. Nothing is sent: attach it to your message on the [support page](support.html).
3. Or click **Copy Short Report** — versions and the app’s self-checks, shown on screen first — and paste it.

{{name}} keeps no log files: it writes to the macOS system log. The ZIP holds the short report, the settings, the profiles by number — running or not, their connection and settings — and this run’s log. A build without the App Sandbox (**Settings → About → Build**) adds the system log of the last 30 minutes: after a crash, collect the ZIP within that time. A sandboxed build gives a Terminal command for it instead.

What {{name}} puts in it leaves out profiles’ names, tags and notes, proxies’ addresses and credentials, passwords, cookies, history and addresses visited; in its own log lines your data shows as \`<private>\`. On every CI build \`check_log_privacy.py\` fails if {{name}}’s code logs in clear anything but an id, a count, a status or a name from the code; the self-test searches a ZIP’s bytes for a profile’s name, notes and proxy password. {{unv:whether WebKit’s own lines in the system log hold page addresses in clear}}

::: warn
Never send your master password, your account password, cookie export files — whoever has one is signed in as that profile — or a proxy list exported with passwords.
:::`,
};
