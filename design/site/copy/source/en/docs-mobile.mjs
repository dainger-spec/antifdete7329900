// Docs: “Mobile view: iPhone and iPad”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-mobile.md.
export default {
  title: 'Mobile profiles: the iPhone and iPad views',
  lead: 'A profile can call itself an iPhone or an iPad to websites. How to turn this on, what changes, and what stays this Mac\'s.',
  toc: [['what', 'What a mobile view is'], ['enable', 'Turning it on'], ['changes', 'What changes'], ['same', 'What stays the Mac\'s'], ['check', 'Checking it'], ['limits', 'What a mobile view cannot do']],
  body: `## What a mobile view is {#what}

A mobile profile in {{name}} is a mobile view: Safari on this Mac calling itself an iPhone or an iPad to websites, in a window the size of that device's screen. Nothing else of the phone or tablet comes with it. Pages are shown by this Mac's WebKit — the engine of its Safari.

This is a real state of Safari: its Develop menu can give it an iPhone's User-Agent in the same way.

## Turning it on {#enable}

1. Open the profile editor: **New Profile**, or ⋯ → **Edit…** in the profile's row.
2. Under **Identity**, open **View for websites** and choose one of:
   - **Mobile view: iPhone, Safari 27 (User-Agent only)**
   - **Mobile view: iPhone, Safari 26 (User-Agent only)**
   - **iPad view: Safari 26, an iPad-sized window**
3. Below the list, the editor explains what the view is. Read it: it is the main limitation.
4. Click **Save**. The view applies from the next launch; stop a running profile and launch it again.

The profile list's **Appears as** column then reads, for example, "Mobile view · Safari 27" or "iPad view · Safari 26". To go back, choose **Safari on macOS 26 (matches this engine)**, the default.

## What changes {#changes}

Two things change: the User-Agent string — in every request's header and in \`navigator.userAgent\` — and the window's size.

| | iPhone | iPad |
|---|---|---|
| User-Agent | Safari on an iPhone: \`iPhone OS 18_7\`, then \`Version/27.0\` (Safari 27) or \`Version/26.6\` (Safari 26) | Safari on a Mac with \`Version/26.6\`: an iPad asks sites for their desktop version by default and calls itself a Mac |
| Window | 390 × 844 points | 820 × 1180 points |

- \`18_7\` is not a mistake: Safari on iOS 26.1 and later always writes it and names the release only after \`Version/\`.
- The **User agent** field below shows the whole string. Its version is fixed in {{name}} and does not follow Safari on this Mac; a mobile view has no **Safari version in the User-Agent** choice.
- **Custom user agent** replaces the string; the window keeps the chosen device's size.
- The size is the page area below the toolbar; from the second tab on, the tab bar takes part of it. The window cannot be made wider or taller, and the size under **Window** does not apply to a mobile view.
- Where profiles open in Safari's own window, a mobile view still opens in a {{name}} window: Safari's window is a Mac's.

## What stays the Mac's {#same}

Everything a page can measure, apart from the User-Agent and the window:

- the engine: this Mac's features, CSS and JavaScript;
- \`navigator.platform\`, \`maxTouchPoints\` (the touch points) and the number of processor cores;
- the screen: its size, colour depth, pixel density and CSS media queries;
- touch: there is none — WebKit on the Mac is a desktop engine;
- fonts, graphics (WebGL) and audio;
- the TLS handshake and the order of headers.

The time zone, language, proxy and every other setting are the profile's own.

::: warn
The editor says it plainly: "An iPhone in a window on a Mac is Safari on the Mac calling itself an iPhone: there is no touch, and the fonts, graphics and audio are this Mac's; a site that checks for touch will see it."
:::

## Checking it {#check}

⋯ → **What Sites See…** → **Take Snapshot**. One page of this Mac opens in a window of the profile, then in Safari, and the panel compares what each saw. A mobile view has no reference, and the panel says so: it compares the profile with Safari on this Mac, not with an iPhone, and cannot see the real device's touch, fonts, graphics, audio, motion sensors or screen.

The build's self-test checks an iPhone view: its navigator, screen, touch, rendering and fonts match plain WebKit on this Mac, and only the User-Agent says "iPhone". {{unv:this check's result in a registered CI run}}

## What a mobile view cannot do {#limits}

WebKit's public APIs on the Mac cannot:

- declare another screen — a screen-size override exists only in WebKit for iOS;
- add touch — WebKit for macOS has no touch emulation;
- bring in an iPhone's engine, fonts or graphics.

An iPhone's real signals take Safari on a real iPhone. {{name}} has no profile that runs Safari for iOS, with its own engine, fonts and touch.

::: unv
Whether the window fits the screen. An iPad view opens 1180 points tall — taller than the screen of any MacBook in the editor's size list (the tallest is 1117 points) — and the code does not fit a mobile view's window to the screen, unlike the size under **Window**. A launch of an iPad view on a MacBook, with the window measured, would confirm it.
:::

::: unv
Whether a profile with Safari for iOS will come. Work on one on Apple's iOS Simulator is shelved (docs/IOS_SIMULATOR.md), while ROADMAP.md lists it for after launch. The owner's decision would confirm it.
:::`,
};
