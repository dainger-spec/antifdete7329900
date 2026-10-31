// Docs: “Creating a profile”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-profile.md.
export default {
  title: 'Creating a profile',
  lead: 'How to create a profile, what each field of the editor sets, and how to launch, stop, change and delete a profile.',
  toc: [['create', 'Creating a profile'], ['editor', 'The editor\'s fields'], ['launch', 'Launching and stopping'], ['window', 'The profile\'s window'], ['edit', 'Editing, copying and deleting']],
  body: `## Creating a profile {#create}

1. In the profiles window, click **New Profile** (⌘N), or choose **New Profile…** in the command palette (⌘K). With no profiles yet, the button also sits mid-window.
2. The **New Profile** editor opens with a name filled in — "Profile" and a number. Change it as you like; it cannot be empty.
3. Set the rest now or later: every field has a default.
4. Click **Save**. The profile appears under **Ready**; it does not start by itself.

**Cancel** closes the editor without saving.

## The editor's fields {#editor}

The editor is one screen in seven parts; the list on the left jumps to each. Changes apply at the next launch.

| Part | Fields | Default |
|---|---|---|
| **Profile** | **Name**, **Glyph**, **Tags**, **Notes**, **Start URL**, **Search engine**, **Ephemeral** | blank start page, DuckDuckGo, persistent |
| **Connection** | **Connection**: **No Proxy**, **From the List** or **New**; **WebRTC** | **No Proxy**, WebRTC **Disabled** |
| **Identity** | **View for websites**, **Safari version in the User-Agent**, **Custom user agent** | **Safari on macOS 26 (matches this engine)**, this Mac's Safari version |
| **Window** | **Window size** | **Custom size**, picked at random |
| **Location and Language** | **Geolocation**, **Time zone and language** | **Deny**, **From the connection** |
| **Privacy** | **Local requests**, **Safe Browsing (lookups bypass the proxy)** | **Protect**, Safe Browsing off |
| **Data** | **Cookies**, **History**, **Passwords**, **Sync** | history kept for **3 months**; password AutoFill and cookie sync on |

For new profiles, the search engine, time zone and language, local requests and window size come from Settings (⌘,) → **New Profiles**, shown here as first set.

### Profile

The **Glyph** (a colour and up to two letters of your own), **Tags** and **Notes** are for you alone: the list finds profiles by them, and no site sees them. The **Start URL** is the first page at launch.

An **Ephemeral** profile writes no website data or history to disk, so none of it outlives a stop; bookmarks are still kept. Its row says "Ephemeral · nothing kept"; the **Ephemeral** filter lists them all.

### Connection and identity

Proxies and WebRTC: see [Proxies: setup, and when one fails](docs-proxy.html).

**View for websites**: Safari on this Mac, an iPhone or an iPad (see [Mobile view](docs-mobile.html)); either way, this Mac's WebKit shows the pages. **Safari version in the User-Agent** changes only the version named — one from another major release is marked risky. **Custom user agent** replaces the whole string.

### Window

**Window size**: **As it is (real device)**, a MacBook Air's or Pro's screen below the menu bar, or a **Custom size** in points. New profiles get a random size that fits the screen, so they do not all open alike. Pages measure this real window; the screen they are told about stays this Mac's.

### Location and language

No field is called "country". **From the connection** uses the time zone and language of where the proxy comes out, looked up through the proxy at each launch; without a proxy, this Mac's. **Manual** sets your own; **Random** keeps one country's pair until you click **Pick another**.

WebKit takes the language once per run: profiles sharing the app's process get the first started one's; a profile running as its own app has its own.

::: note
The editor has no warm-up country. Choose it under ⋯ → **Warm Up…**: a **Ready-made list** from **By country**, or **Put together for me**, which puts the proxy country's sites first.
:::

### Data

Cookies pasted or dropped into **Cookies** reach a new profile at its first launch, before the first page. See [Importing and exporting cookies](docs-cookies.html).

## Launching and stopping {#launch}

1. In the profile's row, click **Launch**. While it starts, the row says "Starting…".
2. The profile moves to **Running**, and its row shows **New Window** and **Stop**.
3. **Stop** closes the profile and encrypts its data — the row says "Encrypting data…". Then the profile is back under **Ready**.

Closing a profile's last window stops it too. To launch several at once, see [Several profiles at once](docs-multiple.html).

## The profile's window {#window}

The window depends on **Each profile its own app in the Dock** (Settings → **Behavior**):

- On (the default): the profile is an app of its own — its own process, a Dock icon with its initials, and Safari's own window with its address bar, tabs and menus; tabs, zoom and downloads follow Safari's settings.
- Off: profiles open in {{name}}'s windows, with the address field and the profile's chip at the top: its glyph, name and the flag of the country its proxy exits in.

iPhone and iPad views, and a profile whose WebRTC goes through the network extension, always open in a {{name}} window.

::: unv
Which build customers get. The switch exists only in the build without the App Sandbox; the sandboxed build — the default of \`scripts/release.sh\` — shows "Not in this build" and opens every profile in {{name}}'s windows. Settled by the owner's choice of the released build.
:::

## Editing, copying and deleting {#edit}

### Edit

⋯ in the profile's row (or a right-click on the row) → **Edit…** opens the same editor. A running profile picks up the changes after a restart.

### Make a copy

There is no Duplicate command. Export makes a copy with all the data: ⋯ → **Export Profile…** (the file gets a password of its own), then **⋯** next to **New Profile** → **Import Profile…**, which adds it as a new profile; **Profile name** can rename it.

### Delete

⋯ → **Delete…**, then **Delete Profile and All Its Data**. The profile's cookies, site data, cache, settings, history, bookmarks and saved passwords are deleted; a running profile is stopped first. To keep a copy, export it first.`,
};
