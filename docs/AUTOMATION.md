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

Selectors are CSS, or `text=…` for the smallest visible elements whose text holds it. Neither
looks into a web component's own elements (an open shadow root): `host >>> inner` does — `inner`
(CSS or `text=`) inside the shadow root of each element `host` finds, and again for a component
in a component (`a >>> b >>> c`). Clicks aim at the element itself there, not at its host.

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
- **"scenario runs"**: a scenario's commands in order with its log; an error ends the run with
  its reason **and the scenario's line** — a command's, and the script's own mistake; what the
  script returns is the run's result; Stop; commands without `await` held to their limit; a plan
  that loses automation. `scripts/test-shims.mjs` runs the line and result code itself
  (`ScenarioRunner.lineSupport`) in V8 and in JavaScriptCore.

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
- `log(...)` for the run's log, `sleep(ms)`, `params` (the run's parameters, read-only: the
  profile's own values — "A profile's values" below — under what an API request gave).
  `sleep(Infinity)` — or any wait longer than a year — waits until Stop; a negative number or
  `NaN` does not wait. A `type` delay is held to a year a key the same way (`ScenarioWait`:
  a number past what the system's sleep holds stopped the profile's process).

A script's commands act one at a time, in the order they were asked for, whatever the script awaits
(two at once — a forgotten `await`, `Promise.all` — moved one pointer two ways). Lines logged faster
than the app shows them are counted, not queued: past 500 waiting, the log says how many it left out
(a script logging in a loop used to hold up the profile's windows, and Stop behind them). Commands
asked for and not answered yet are held to 1,000 (`ScriptGate`): past that, the call throws
"1000 page commands are waiting to run: write await before each one", which ends the run unless the
script catches it (a loop that called `page.scroll(…)` or `sleep(…)` without `await` queued them
without end, and its process's memory with them).

A command that fails rejects its promise with the reason (the script may `try`/`catch` it); one left
uncaught ends the run with it. **The error names the scenario's line**: "no element matches #next
(line 12)", and `scenarioLine` on the error for a script that catches it. A command's failure is
made by the app outside any call of the script, so its own stack knows no line: the line is read
where the command is called (`ScenarioRunner.lineSupport`, the first frame of `scenario.js` in a
stack made there) and added once. The script's own mistakes and thrown errors get theirs the same
way from their own stack, and a script that does not parse the line the reading stopped at.
"stopped" stays as it is.

**What the script returns is the run's result** (`return {orders: 3}`): JSON, kept as the log's
`result` line (`ScenarioRunState.result`), shown in the editor's log and given as `result` by the
API — data out of a run without reading log lines. Up to 512 KB; a larger one is left out, and the
log says so. Nothing returned is no result.

Stop ends the run at once: a command that is waiting — `sleep`,
`waitFor`, a page still loading — stops waiting (it used to run to its end: a script sleeping an hour
kept its run going for the hour), and a pressed button or key is let go first. From Stop on — and once
the run has ended in any way — every page command, `sleep` and `log` the script still calls throws
"stopped" at once, on the script's own thread, without reaching the page: a loop that calls any of
them ends with the run, awaited or not (it used to run on after Stop, each call one more hop to the
main thread). A loop that calls none of them — `while (true) {}`, or one that catches "stopped" and
goes on — cannot be interrupted: its thread stays busy after Stop until the profile's process ends,
when the profile stops (with every profile in Lumen's own process — the sandboxed build,
`PBProfileProcess` off — until Lumen quits). The app and the page are not held up meanwhile.

The plan's `features` must name `automation` (docs: the document of rights, format 1; absent —
off): the trial, Professional and Team have it, Personal does not (the owner and the lead,
9 November). It is asked before each command: a plan that loses it mid-run lets the step under way finish,
runs no other, and the log says why.

The scenarios are kept in `scenarios.bin` at the vault's root under its own key; this Mac's only
(not synced in this version).

### A profile's values

One scenario for fifty profiles needs each profile's own login and password. The recorder writes
`params.password` for every password it does not record — and a run started from the editor or by
the clock had nothing there: only an API request could give `params`, so a recorded sign-in typed
an empty password.

- **`ScenarioValues`** (BrowserCore): for each profile, names and their text — `login`, `password`,
  anything. A name is what can follow `params.`: a Latin letter or `_`, then letters, digits, `_`
  (64 at most); a value up to 4,096 characters, 64 values a profile. `scenario-values.bin` at the
  vault's root, sealed under the scenarios' key — a file of its own, as the schedules' is. This
  Mac's; not synced, not part of a profile's export or copy.
- **A run's `params`** (`ScenarioValues.parametersJSON`): the profile's values, each as text —
  from the editor's Run, from a schedule, and from an API request that names a **saved** scenario,
  where what the request gave in `params` wins name by name. A text sent with the request
  (`{"source": …}`) gets the request's own `params` and no more: what is kept for a profile is
  read by the scenarios the person wrote, not by whatever holds the API's token.
- **In the editor**: the values of the chosen profile open from the button beside the profile's
  name; the names the scenario on screen reads (`ScenarioValues.namesRead`: `params.name`,
  `params['name']`) are offered to fill in, and those the profile has no text for are named under
  the run's bar before the run ("This profile has no value for: password").
- A profile the person deletes takes its values with it (`AppModel.deleteProfile`). The run's log
  never holds a value: typing is logged by its length.

Where a person finds it (the owner, 10 November: behind File › Scenarios alone it was hidden, and what
a scenario may say was in this file only): the Profiles window's sidebar has Scenarios, Automation
API and Help beside Profiles and Proxies, and "Commands and Search" (⌘K) above them; the editor's
Commands button, the automation settings and Help › Lumen Help (⌘?) open the app's own help
(`HelpView`) — how a scenario is run, every command with what it takes, the API's requests with
commands to copy, connecting Selenium — in the interface's language. The Help menu lists the
topics, so the menu bar's own search finds each by its name.

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
   Stop Recording ── ScenarioRecording.line(for:) per step, added to the end of the scenario the
               recording was for (AppModel.recordingScenario) — or put in place of the example a
               new scenario begins with, while that example is untouched
```

- **The scenario it is for.** A recording belongs to the scenario on screen when Record was
  pressed. The list keeps to it until the recording ends; the editor's window closed and opened
  again shows that scenario, not the list's first; and the steps go to it whatever is on screen
  when the recording ends (a scenario deleted meanwhile: a new one gets them).

- **Selectors**, in this order: an `id` that is unique and not made for this load only (`:r1:`,
  `ember123`, long runs of digits); `data-testid`, `data-test-id`, `data-test`, `data-qa`,
  `data-cy`; `name`, `aria-label`, `placeholder`, `title` with the tag; for a link or button, its
  text (`text=…`) when exactly one element has it; else the path from the nearest ancestor that
  can be named, by position among siblings of its kind. An element inside a web component's open
  shadow root is named by the same rules within that root, after its host's selector and `>>>`
  (`body > login-box >>> input[name="email"]`): a selector of the page itself would find nothing
  there on a replay, or a look-alike outside the component. A closed shadow root shows the page
  only its host, which is what is recorded.
- **A password is never recorded.** The page's side sends no text for a secret's field, the
  profile's process drops any that came, and the line is
  `await page.type(selector, params.password || '');` with a comment that says so. A secret's
  field is a password field — or one that was while the person was in it (a "show password"
  button makes it a text field) — and any field whose `autocomplete` is `current-password`,
  `new-password`, `one-time-code` (the numeric code fields too) or a card's (`cc-…`); a card's
  month or year chosen in a list is noted without the value.
- **Typing over text.** A field that held text when the person came to it gets
  `click; press('Meta+a'); type` — the typing replaces what was there, as it did.
- **Enter in a form's field** is `page.press('Enter')`; the click the browser makes on the form's
  button for it is not a second step.
- **Not recorded:** frames, dragging, file uploads, hovering; a choice in a `<select>` becomes a
  comment (its list is the system's, not the page's).
- **Only what the person does in a window they see.** A warm-up's pages (its window is in front
  fully transparent) and the page the profile's check measures with are left out. A recording
  ends when its profile stops — its window closed, its process ended — with the lines it has.
- Nothing of the recorder is in a profile's pages before the first recording there. After it the
  script stays, idle: a page's script asks at its start whether a recording is on.

Checked: `ScenarioRecordingTests` (which loads are steps, what typing leaves, each step's line);
the self-test's "automation commands" (a recording of the driver's own click and typing comes out
as the lines that repeat them, and nothing is recorded after Stop); the page's script against
real input in a browser while it was written (the fields, a password, a checkbox's label, a
button without an id, Enter); `scripts/test-shims.mjs` runs the page's script and the driver's
find on a stub page — secrets, and a field and a button in a component's shadow root named
through its host and found there rather than in a look-alike form of the page.

## By the clock

The editor's **Schedule** (bottom left, with how many are switched on): a scenario, or a
profile's warm-up, every day at a time or every so many hours, with a random shift either way.
**On a Schedule…** beside Run opens the same list with the form filled in for the scenario on
screen and the chosen profile. A row says when its schedule runs next and how the last run went —
that it was made, and once it has ended, **how it ended**: "finished in 42 s", "failed: no element
matches #login (line 7)" as the row's warning, or stopped (by hand, with its profile, by the
plan); deleting one asks first; saving a change leaves the schedule's switch as it was.

- `ScenarioSchedule` (BrowserCore): what (`.scenario(id)` or `.warmUp`), the profile, when
  (`.daily(hour:minute:)` or `.every(hours:)`), the jitter in minutes, and the next run with its
  random part already in it. `ScenarioSchedules` is `scenario-schedules.bin` at the vault's root,
  sealed under the scenarios' key — a file of its own, so a version from before schedules never
  sees it and `scenarios.bin` is written as before. This Mac's; not synced.
- `ScenarioScheduleCoordinator` looks at the clock once a minute while the vault is open: a due
  scenario is run as the editor's Run runs it (`AppModel.runScenario`), a due warm-up goes into
  the warm-up queue with the profile's own plan. A profile that is starting, being sealed,
  running a scenario, being recorded in or driven by a WebDriver session is looked at again ten
  minutes on. A run found more
  than six hours late is not made ("missed"); without automation in the plan nothing is run and
  the schedule says so. Schedules of deleted profiles and scenarios go with them.
- **How a run ended** (`ScenarioSchedule.lastEnd`: finished, failed, stopped; the reason's first
  line; when; how long): a schedule recorded only that its run started, and a scenario that failed
  at its third step every night said "Last run: …" all the same. The coordinator gives each run it
  starts an id and hears every run's end (`ProfileManager.onScenarioEnded` →
  `ScenarioScheduleCoordinator.runEnded`); the end of a run it started is written to that
  schedule, a run's start takes the end of the one before away. A warm-up's schedule keeps none:
  the warm-up's own screen says how that went. A file from before has no ends and reads as it did.
- Nothing wakes the Mac or starts the app: a schedule runs while Lumen does.
- A scheduled run does not take the keyboard: its window is put in front without being made the
  key window and without activating the app (`openScenarioPage(inBackground:)`), so what the
  person is typing into elsewhere keeps it. Run, pressed by the person, brings its window forward.
- The plan: schedules, like scenarios, need automation (`allowsAutomation`). In a plan without it
  the saved schedules do not run, and can be switched off or deleted — not added, changed or
  switched on. The warm-up's own "every N hours" (the warm-up screen) is as it was, in every plan;
  the form says so when a warm-up by the clock would run beside it.

Checked: `ScenarioScheduleTests` (the next run today or tomorrow, the random part within its
limits, due, late, a run's record, how a run ended and a file from before ends were kept, the file).

## WebDriver

A team's own Selenium scripts run on a profile as they do on Safari: the app answers the W3C
WebDriver protocol itself.

**What was looked at first.** The system's `safaridriver` cannot be pointed at a profile: it starts
and drives Safari.app only — there is no way to hand it a window of Safari's hosted in another
process — and a page it drives is told so (`navigator.webdriver` is true, a banner in the window).
So the protocol is served here, over what scenarios already use: the same page driver, with the
pointer and the keys a page takes for a person's.

```
a client (Selenium) ── http://127.0.0.1:<port>/wd/<profile's token>/<profile>/session…
   AutomationServer (the API's own listener, 127.0.0.1 only) ── a path under /wd/:
       AutomationGate.webDriverRefusal (no web page's request, the Host this listener's),
       WebDriverRoute.parse (BrowserCore: the protocol's commands by method and path),
       the token of the address against the profile's own (WebDriverRoute.token, constant time)
   WebDriverService ── the plan (allowsAutomation); the profile the address names; its sessions
       new session: the profile started if it is stopped, without a window of its own
                    ("open": the window the commands act in), capabilities back
       a command:   ProfileManager.webDriver(id, WebDriverCall) ── ProfileCommand.webDriver to the
                    profile's own process, answered by ProfileEvent.webDriverAnswer (by the call's id)
       quit:        "close"; a profile the session started is stopped
   WebDriverExecutor (where the window is) ── PageDriver for a window of Safari's, the session's
       own (SafariChromeHost.openScenarioPage(forWebDriver:): never a run's) or, where Safari's
       chrome is not hosted, of the app's own
       navigate (http, https or about:blank only; else "invalid argument"), back, forward,
       refresh, title, url, source ── PageDriver
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

- **The address** is the API's listener, the profile's own token and the profile: one for each
  profile, shown in its inspector (**WebDriver Address**: the token as dots, and Copy, which gives
  the whole address) and copied from the profile's ⋯ menu (**Copy WebDriver Address**) while the
  API listens. With the API off, on but not started, or not in the plan, the inspector has a row
  **Selenium** that says which and opens where that is settled. The token is in the path because
  a WebDriver client sends no header of ours, and so it is not the API's token: it is the
  profile's own, made from it —

  ```
  base64url without padding of HMAC-SHA256(key = the API's token (UTF-8),
                                           message = "webdriver:" + the profile's UUID, upper case)
  ```

  (`WebDriverRoute.token`; `scripts/pbctl webdriver <profile>`, a developer script of this source
  repository that the app does not ship, prints the address). Under `/wd/`
  only that profile's token is taken, for that profile alone — not the API's token, not another
  profile's; under `/v1/` only the API's. So an address given to a script, or left in its logs,
  drives that one profile and nothing else of the API. Renewing the API's token changes every
  profile's address. 127.0.0.1 only.
- **A session is a launch.** One session a profile at a time; ending it closes its window, and
  stops the profile when the session started it (a profile that was running stays — out of
  sight, too: the session's window closing is not the profile's last window closing).
- **A window of its own.** A session never acts in a scenario's run's window, and no run takes
  the session's: a run started from the editor opens its own. While a session drives a
  profile, a schedule's run on it waits (the profile is busy, looked at again ten minutes on)
  and the API's run is refused (`409 busy`).
- **Many profiles at once:** one script per profile, side by side, as many as the plan's
  profiles. A command being answered — a launch, a page's load, a find's implicit wait — holds
  no other up; only connections still sending their request are limited (32 at once), and one
  past that is answered with the protocol's `unknown error` ("Too many requests are arriving at
  once"), not acted on, and can be sent again (docs/AUTOMATION_API.md).
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
- **Clients:** Selenium in any language, WebdriverIO, or anything else that speaks the protocol.
  A web page's request is refused (it carries `Origin` or `Sec-Fetch-Site`); Node's built-in
  `fetch`, which WebdriverIO sends every command with, adds `Sec-Fetch-Mode` alone of those
  headers, and that is answered.

### Selenium (Python)

```python
from selenium import webdriver
from selenium.webdriver.common.by import By

# The profile's inspector: WebDriver Address → Copy
driver = webdriver.Remote(
    command_executor="http://127.0.0.1:50777/wd/<profile's token>/<profile>",
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
