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

**Where it acts** (the owner, 10 November: a run in a window of the app's own is not Safari). In a
profile's own process that hosts Safari's chrome, the run opens a window of Safari's for itself, on
an empty page (`SafariChromeHost.openScenarioPage`), acts on its tab's web view and goes to
addresses through the tab (`loadURL:`), as the address bar does. A profile that was stopped is
started without a window of its own, so the run's is the only one. Everywhere else — an iPhone or
iPad view, the sandboxed build, a macOS where the chrome is not hosted — it is a window of the
app's, as before; and when Safari's window gives no page to act on within a few seconds, the run
goes on in a window of the app's rather than being lost. The run's log says which, in its first line. In Safari's window the page may run
under the toolbar, so the viewport's place in the web view is measured, not assumed: the page is
asked, from the driver's own world, where it saw a move of the input (`PageDriver.measureViewport`).
`Lumen --scenario-safari-check` (scripts/scenario_safari_check.sh, the full pipeline, macOS 26 and
27) holds it: a run in Safari's window must leave a trusted click inside the button it aimed at, in
the page's own record.

- `page`: the core commands above, each returning a promise (`await page.click('#login')`);
  `page.evaluate(fn, arg, {world: 'page'})` takes a function or a function body;
  `page.url()` and `page.title()` are promises too (in Playwright they are not);
- `log(...)` for the run's log, `sleep(ms)`, `params` (the run's parameters, read-only).

A script's commands act one at a time, in the order they were asked for, whatever the script awaits
(two at once — a forgotten `await`, `Promise.all` — moved one pointer two ways). Lines logged faster
than the app shows them are counted, not queued: past 500 waiting, the log says how many it left out
(a script logging in a loop used to hold up the profile's windows, and Stop behind them).

A command that fails rejects its promise with the reason (the script may `try`/`catch` it); one left
uncaught ends the run with it. Stop ends the run at once: a command that is waiting — `sleep`,
`waitFor`, a page still loading — stops waiting (it used to run to its end: a script sleeping an hour
kept its run going for the hour), and a pressed button or key is let go first. A script that loops without ever awaiting keeps its thread busy after
Stop until the profile stops — the app and the page are not held up.

The plan's `features` must name `automation` (docs: the document of rights, format 1; absent —
off): the trial, Professional and Team have it, Personal does not (the owner and the lead,
9 November). It is asked before each command: a plan that loses it mid-run lets the step under way finish,
runs no other, and the log says why.

The scenarios are kept in `scenarios.bin` at the vault's root under its own key; this Mac's only
(not synced in this version).

Where a person finds it (the owner, 10 November: behind File › Scenarios alone it was hidden, and what
a scenario may say was in this file only): the Profiles window's sidebar has Scenarios, Automation
API and Help beside Profiles and Proxies, and "Commands and Search" (⌘K) above them; the editor's
Commands button, the automation settings and Help › Lumen Help (⌘?) open the app's own help
(`HelpView`) — how a scenario is run, every command with what it takes, the API's requests with
commands to copy — in the interface's language.

## Recording

A scenario can be recorded from what a person does (the editor's **Record**, beside Run).

```
Record ── AppModel.startRecording(on:) ── the profile started with a window if it is stopped
   ProfileManager.startRecording ── ProfileCommand.startRecording to the profile's own process
                                    (or BrowserSession.startRecording in this one)
   BrowserSession: ScenarioRecorder's script and handler go into every content controller of the
                   profile at the first recording there (and into each made after: applyContent,
                   restoreContent); the pages shown are told to watch
   the page ── ScenarioRecorderScript, in a world of its own, the main frame: trusted clicks, what a
               field holds once the typing is over, Enter in a field → {click | fill | press | note}
               with a selector; every page's script says "hello" with its address at its start
   ScenarioRecorder ── Event.loaded(address) | .acted(step) ── ProfileEvent.recorded ── the app
   AppModel.recorded: ScenarioRecording ── which loads are steps (the first page and an address
               opened: goto; a page that follows a click or Enter within 5 s: waitForLoadState, once)
   Stop Recording ── ScenarioRecording.line(for:) per step, added to the scenario's end
```

- **Selectors**, in this order: an `id` that is unique and not made for this load only (`:r1:`,
  `ember123`, long runs of digits); `data-testid`, `data-test-id`, `data-test`, `data-qa`,
  `data-cy`; `name`, `aria-label`, `placeholder`, `title` with the tag; for a link or button, its
  text (`text=…`) when exactly one element has it; else the path from the nearest ancestor that
  can be named, by position among siblings of its kind.
- **A password is never recorded.** The page's side sends no text for a password's field, the
  profile's process drops any that came, and the line is
  `await page.type(selector, params.password || '');` with a comment that says so.
- **Typing over text.** A field that held text when the person came to it gets
  `click; press('Meta+a'); type` — the typing replaces what was there, as it did.
- **Enter in a form's field** is `page.press('Enter')`; the click the browser makes on the form's
  button for it is not a second step.
- **Not recorded:** frames, dragging, file uploads, hovering; a choice in a `<select>` becomes a
  comment (its list is the system's, not the page's).
- Nothing of the recorder is in a profile's pages before the first recording there. After it the
  script stays, idle: a page's script asks at its start whether a recording is on.

Checked: `ScenarioRecordingTests` (which loads are steps, what typing leaves, each step's line);
the self-test's "automation commands" (a recording of the driver's own click and typing comes out
as the lines that repeat them, and nothing is recorded after Stop); the page's script against
real input in a browser while it was written (the fields, a password, a checkbox's label, a
button without an id, Enter).

## By the clock

The editor's **Schedule** (bottom left): a scenario, or a profile's warm-up, every day at a time
or every so many hours, with a random shift either way.

- `ScenarioSchedule` (BrowserCore): what (`.scenario(id)` or `.warmUp`), the profile, when
  (`.daily(hour:minute:)` or `.every(hours:)`), the jitter in minutes, and the next run with its
  random part already in it. `ScenarioSchedules` is `scenario-schedules.bin` at the vault's root,
  sealed under the scenarios' key — a file of its own, so a version from before schedules never
  sees it and `scenarios.bin` is written as before. This Mac's; not synced.
- `ScenarioScheduleCoordinator` looks at the clock once a minute while the vault is open: a due
  scenario is run as the editor's Run runs it (`AppModel.runScenario`), a due warm-up goes into
  the warm-up queue with the profile's own plan. A profile that is starting, being sealed,
  running a scenario or being recorded in is looked at again ten minutes on. A run found more
  than six hours late is not made ("missed"); without automation in the plan nothing is run and
  the schedule says so. Schedules of deleted profiles and scenarios go with them.
- Nothing wakes the Mac or starts the app: a schedule runs while Lumen does.
- The plan: schedules, like scenarios, need automation (`allowsAutomation`). The warm-up's own
  "every N hours" (the warm-up screen) is as it was, in every plan.

Checked: `ScenarioScheduleTests` (the next run today or tomorrow, the random part within its
limits, due, late, a run's record, the file).

## WebDriver

A team's own Selenium scripts run on a profile as they do on Safari: the app answers the W3C
WebDriver protocol itself.

**What was looked at first.** The system's `safaridriver` cannot be pointed at a profile: it starts
and drives Safari.app only — there is no way to hand it a window of Safari's hosted in another
process — and a page it drives is told so (`navigator.webdriver` is true, a banner in the window).
So the protocol is served here, over what scenarios already use: the same page driver, with the
pointer and the keys a page takes for a person's.

```
a client (Selenium) ── http://127.0.0.1:<port>/wd/<token>/<profile>/session…
   AutomationServer (the API's own listener, 127.0.0.1 only) ── a path under /wd/:
       AutomationGate.webDriverRefusal (no web page's request, the Host this listener's),
       WebDriverRoute.parse (BrowserCore: the protocol's commands by method and path),
       the token of the address against the API's (constant time)
   WebDriverService ── the plan (allowsAutomation); the profile the address names; its sessions
       new session: the profile started if it is stopped, without a window of its own
                    ("open": the window the commands act in), capabilities back
       a command:   ProfileManager.webDriver(id, WebDriverCall) ── ProfileCommand.webDriver to the
                    profile's own process, answered by ProfileEvent.webDriverAnswer (by the call's id)
       quit:        "close"; a profile the session started is stopped
   WebDriverExecutor (where the window is) ── PageDriver for a window of Safari's
       (SafariChromeHost.openScenarioPage) or, where Safari's chrome is not hosted, of the app's own
       navigate, back, forward, refresh, title, url, source ── PageDriver
       find (css selector, xpath, link text, partial link text, tag name), with the implicit wait
       click ── the element brought into view, the point checked for what covers it, then the
                pointer moved there and pressed (PageInput); an <option> is chosen in its list
       send keys ── the element focused, then keys one by one; the protocol's own key codes
                (Enter, Tab, Backspace, arrows, Shift/Control/Alt/Meta held until NULL) through
                WebDriverKeys; text the keyboard's layout has no key for is put in as text
       text, tag, attribute, property, CSS value, rect, enabled, selected, displayed, clear
       execute/sync and /async ── the client's script in the driver's own world
       cookies of the page ── the profile's store (WKHTTPCookieStore)
       screenshot (the viewport, an element), the window's rectangle, timeouts
```

- **The address** is the API's listener and token plus the profile: one for each profile, shown
  in its inspector (**WebDriver Address**, with Copy) while the API is on. The token is in the
  path because a WebDriver client sends no header of ours; whoever has the address drives the
  profile, as whoever has the token uses the API. 127.0.0.1 only.
- **A session is a launch.** One session a profile at a time; ending it closes its window, and
  stops the profile when the session started it (a profile that was running stays).
- **What a page can tell.** Nothing new: `navigator.webdriver` stays false, and clicks and keys
  are the driver's own (docs/PAGE_INPUT.md). `clear`, choosing an `<option>` and text put in
  where the layout has no key set values from the driver's world, as AutoFill does.
- **Scripts run in the driver's world**, not the page's: the DOM is the same, an element can be
  an argument and a result, but the page's own JavaScript variables are not seen. That is what
  lets an element cross to the script without marking it in the page.
- **Not there:** frames, the page's dialogs (alert, confirm), several windows or tabs in one
  session, the Actions API (ActionChains), file uploads, printing. Each answers with the
  protocol's own error ("unsupported operation", "no such alert").
- **The plan:** part of automation (`allowsAutomation`), refused without it with the reason.

### Selenium (Python)

```python
from selenium import webdriver
from selenium.webdriver.common.by import By

# The profile's inspector: WebDriver Address → Copy
driver = webdriver.Remote(
    command_executor="http://127.0.0.1:50777/wd/<token>/<profile>",
    options=webdriver.SafariOptions())

driver.implicitly_wait(10)
driver.get("https://example.com/login")
driver.find_element(By.CSS_SELECTOR, "#email").send_keys("name@example.com")
driver.find_element(By.XPATH, "//button[@type='submit']").click()
print(driver.find_element(By.CSS_SELECTOR, "h1").text)
driver.save_screenshot("after.png")
driver.quit()   # closes the window; a profile the session started is stopped
```

Any options object will do (the capabilities asked for are not matched): the browser is the
profile's, whatever is named.

### Playwright

Playwright cannot be connected. It drives only its own builds of browsers (its WebKit is not
Safari and is spoken to by Playwright's own protocol), and its `connectOverCDP` is Chromium's.
Its script moves into a scenario of this app almost as it is — the commands have its names:

| Playwright | A scenario here |
|---|---|
| `await page.goto(url)` | `await page.goto(url)` |
| `await page.click(selector)` | `await page.click(selector)` |
| `await page.fill(selector, text)` | `await page.type(selector, text)` |
| `await page.press(selector, 'Enter')` | `await page.press('Enter')` |
| `await page.waitForSelector(selector)` | `await page.waitFor(selector)` |
| `await page.textContent(selector)` | `await page.textContent(selector)` |
| `await page.evaluate(fn, arg)` | `await page.evaluate(fn, arg)` |
| `await page.screenshot()` | `await page.screenshot()` |

and a scenario is started from outside through the API (`POST /v1/profiles/{profile}/scenario`,
docs/AUTOMATION_API.md).

### Checked

`WebDriverProtocolTests` (the commands by method and path as Selenium sends them, the errors, the
keys as strokes). The page's scripts against a real browser while they were written (finding by
CSS and XPath, an invalid selector, a covered element, an option, clear, a script with elements in
and out, a stale reference). In the full pipeline, `scripts/webdriver_check.sh`: `Lumen
--webdriver-serve` over a temporary vault, and `scripts/webdriver_check.py` with Selenium's own
client — a session starts the profile in a process of its own with Safari's window, opens the
self-test proxy's form, finds the field by CSS, types, finds the button by XPath, clicks, reads
the text; then a script with an element, a cookie, a screenshot, the window's size, and quit.
