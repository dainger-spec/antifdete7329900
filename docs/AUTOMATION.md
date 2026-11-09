# Scenario automation

Scenarios act on a profile's pages with the app's own pointer, wheel and keyboard. There is no
debugging protocol: nothing a page could find (`navigator.webdriver`, protocol objects, untrusted
events). The promise is that **a page cannot tell a scenario from a person**, and the self-test
holds every command to it.

Plan (the lead's note v2): 1 the shared input mechanism (`PageInput`, docs/PAGE_INPUT.md);
2 the check group "the page cannot tell"; 3 the core commands (this file); 4 the editor and runs on
a profile, with a log; 5 the local channel; 6 the rest of the commands, each with its checks;
7 humanity and reliability settings; 8 runs on many profiles; 9 JavaScript and Python libraries.
Steps 1–5 are the first version to show.

## Core commands (`PageDriver`)

Names follow Playwright's so that a script moves over quickly; full compatibility is not promised.

| Command | What it does |
|---|---|
| `goto(url, waitUntil)` | Loads the address as the address bar does; waits for another document, then for `load` or `domcontentloaded` |
| `back()`, `forward()`, `reload()` | As the toolbar's buttons; wait for the page |
| `waitForLoadState(state)` | `domcontentloaded` or `load` |
| `waitFor(selector, state, timeout)` | `attached`, `detached`, `visible`, `hidden`; a timeout is an error |
| `click(selector, clickCount)` | Waits for the element, scrolls it into view with the wheel, moves the pointer to a point inside it where it is on top, presses and lets go (2: a real double click); an element covered there is an error naming what covers it |
| `hover(selector)`, `click(at:)` | The pointer over an element; a click at a viewport point |
| `type(selector, text, delay)` | Clicks the field (unless focused), then key after key with Shift held around capitals; a character the keyboard layout has no key for is an error. The log says how many characters, never which |
| `press("Enter" / "Shift+Tab" / "Meta+a")` | A key or a combination, modifier keys pressed before and let go after |
| `scroll(by:)`, `scrollIntoView(selector)` | Wheel events where the pointer is |
| `textContent`, `innerText`, `inputValue`, `getAttribute`, `count`, `isVisible`, `url`, `title` | Read from the driver's own content world |
| `evaluate(body, args, world)` | A function body in the driver's own world by default, which the page's scripts cannot see. In the page's world only when asked for by name: **what runs there, the page can see** (its globals, its prototypes, its timing) |
| `screenshot(selector?)` | A PNG of the viewport or of an element's part in view |
| `pause(range)` | A pause of random length |

Selectors are CSS, or `text=…` for the smallest visible elements whose text holds it.

The driver reads the page (where an element is, whether it shows, its text) in a content world of
its own; it never acts on the page from a script. Clicks, typing and scrolling are input events.

## What proves it (self-test)

- **"the page cannot tell"**: each trace kind with its fix and without it (docs/PAGE_INPUT.md).
- **"automation commands"**: on pages of the self-test proxy, each command does what it says;
  the page's record of the whole run passes the same rules (trusted events, pointer moves before
  every press, the button held, wheel time and place, focus, keys with Shift, a real double click,
  user activation); the run changes nothing of the fingerprint surface (`fingerprint_probe.js`,
  `navigator.webdriver` false) or the page's globals; `evaluate` in the driver's world is not seen
  by the page, while the same in the page's world — the control — is.

## Scenarios (`ScenarioRunner`)

A scenario is JavaScript. It runs in a JavaScriptCore of its own, on a thread of its own — never in
the page — with:

- `page`: the core commands above, each returning a promise (`await page.click('#login')`);
  `page.evaluate(fn, arg, {world: 'page'})` takes a function or a function body;
  `page.url()` and `page.title()` are promises too (in Playwright they are not);
- `log(...)` for the run's log, `sleep(ms)`, `params` (the run's parameters, read-only).

A command that fails rejects its promise with the reason (the script may `try`/`catch` it); one left
uncaught ends the run with it. Stop ends the run at once: a command under way finishes first (a
pressed button is let go). A script that loops without ever awaiting keeps its thread busy after
Stop until the profile stops — the app and the page are not held up.

The plan's `features` must name `automation` (docs: the document of rights, format 1; absent —
off): the trial, Professional and Team have it, Personal does not (the owner and the lead,
9 November). It is asked before each command: a plan that loses it mid-run lets the step under way finish,
runs no other, and the log says why.

The scenarios are kept in `scenarios.bin` at the vault's root under its own key; this Mac's only
(not synced in this version).
