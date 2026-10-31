// Docs: “Several profiles at once”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-multiple.md.
export default {
  title: 'Several profiles at once',
  lead: 'Launch, tell apart and stop several profiles at the same time: what each keeps to itself, what they share, and how many a Mac holds as measured.',
  toc: [['process', 'Each profile is a process'], ['launch', 'Launching and stopping'], ['windows', 'Telling windows apart'], ['isolation', 'What is separate, what is shared'], ['scale', 'How many a Mac holds'], ['warmup', 'Warm-up in turn'], ['crash', 'When a profile crashes']],
  body: `## Each profile is a process {#process}

Every running profile is a macOS process of its own, with its own Safari window and WebKit processes. It holds only its own profile’s key; the other profiles and the proxy list stay in {{name}}’s main process. Its language, region and time zone are set as it starts.

::: note
This holds while **Each profile its own app in the Dock** is on (Settings, **Behavior**; on by default). Off — or where it reads **Not in this build** — all profiles run in {{name}}’s windows in one process, and the first one launched sets the language sites see until you quit. iPhone and iPad profiles always open in a {{name}} window — see [Mobile profiles](docs-mobile.html).
:::

## Launching and stopping {#launch}

1. In the Profiles window, select profiles: ⌘-click adds or removes a row, ⇧-click selects a range.
2. With two or more selected, a bar above the list offers **Launch**, **Stop**, **Warm Up…**, **Assign Proxy…** and **Delete…**
3. **Launch** starts the stopped ones four at a time: each next one once one of those has its window up or has ended, or after two minutes.

**Stop** stops the selected running profiles at once and encrypts their data. Closing a profile’s last window stops it too. **Lock** stops every profile, encrypts their data and forgets the keys; so does ⌘Q, which with **Confirm quitting** on first lists what it will stop.

## Telling windows apart {#windows}

- Each profile is an app of its own in the Dock and the ⌘-Tab switcher, its icon showing the first letters of its name: two by default, or one, three or **None** under **Letters of the name on the Dock icon** (**Behavior**).
- A profile started without a window (for a warm-up or a cookie export) stays out of the Dock.
- A {{name}} window shows the profile’s chip in its toolbar: its **Glyph**, name and the flag of the country its proxy exits in.

::: unv
Whether Safari’s window itself shows the profile’s name has not been checked; a capture of a profile’s window would confirm it.
:::

## What is separate, what is shared {#isolation}

| Each profile’s own | Shared by the profiles of one Mac |
|---|---|
| cookies, localStorage, IndexedDB, cache, service workers | the GPU (canvas, WebGL), audio, system fonts, screen |
| the proxy, for its whole process | CPU core count, \`navigator.platform\`, Safari and WebKit versions |
| language, region, time zone | the macOS network stack: TLS and HTTP/2 fingerprint |
| history, bookmarks, passwords, Safari’s settings | the master password, vault and proxy list |

The self-test checks on every build that running profiles cannot see each other’s site data and load pages at once, each through its own SOCKS5 proxy.

::: note
Hardware and macOS traits are the same in every profile on a Mac, and {{name}} does not alter them: a site can link profiles by them. Full separation takes separate macOS accounts or Macs.
:::

## How many a Mac holds {#scale}

{{name}} sets no limit on how many profiles run at once; the Mac does. Measured on a GitHub CI machine (3 processors, 7 GB of memory, macOS 26 and 27), profiles opening a nearly empty page, all launched at once:

- A profile is 6 to 12 processes and about 150 MB of memory; a real site adds what it adds in Safari, often hundreds of MB a tab.
- Ten started reliably, in 10–40 seconds. Twenty took up to a minute on macOS 26, one to six minutes on macOS 27. Thirty is past that machine: on macOS 27 the last windows came after minutes or not at all.
- The processor gives out first at launch; with real sites, memory bounds how many keep running.
- Stopping took about 5–9 seconds for up to ten, 6–35 for twenty or thirty.
- Quitting with ten running took 5.1–13.6 seconds until all were encrypted; every profile’s cookie was there at its next launch.

::: unv
**Launch** with its queue of four has not been timed; the figures are for all at once. Timing a run through the queue would confirm it.
:::

## Warm-up in turn {#warmup}

1. Select profiles and click **Warm Up…** in the bar, or press ⌘K and choose **Warm Up Several Profiles…**
2. Tick the profiles, choose what to visit and click **Start** (**Add to Queue** while the queue runs).
3. They warm up one at a time with one plan: a stopped one starts without a window and is stopped and encrypted again before the next; an open one warms up where it runs and stays open.

**Cancel the Rest** drops the waiting ones; **Stop All** also stops the current run. Scheduled warm-ups join the queue; an open profile is tried again 10 minutes later.

## When a profile crashes {#crash}

- A crash closes only that profile: each runs in its own process.
- {{name}} encrypts what it left on disk at once and says the profile ended unexpectedly and its data is encrypted — or, if that failed, that this happens at the next unlock.
- If {{name}} itself crashes, the running profiles end too, and whatever is left unencrypted {{name}} encrypts at the next unlock {{unv:whether the profiles manage to encrypt their own data first — no test covers it}}.

::: unv
What a profile keeps after its process crashes is untested; the app says sign-ins and cookies stay, tabs do not. A test that kills the process mid-run and starts the profile again would confirm it.
:::

What to do next: [When something fails](docs-trouble.html).`,
};
