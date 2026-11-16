# Scenario automation

Scenarios act on a profile's pages with the app's own pointer, wheel and keyboard. There is no
debugging protocol: nothing a page could find (`navigator.webdriver`, protocol objects, untrusted
events). The promise is that **a page cannot tell a scenario from a person**, and the self-test
holds every command to it — but one, a choice in a list (`selectOption`), which cannot be made
with the pointer and says what a page can see of it ("The one exception", below).

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
| `waitForLoadState(state)` | `domcontentloaded` or `load`. Right after a click, a key or a choice in a list (within 1.5 s) it first waits for the page that action opens to begin loading: the old page is still "complete" for a moment after the click, and a wait that looked at once went on to read the page being left |
| `waitForURL(pattern, waitUntil, timeout)` | Until the page's address matches, then for the page: an address written out, with `*` for a run of characters within one part of the path and `**` for any run (`'**/account'`), or a regular expression (`/\/orders\/\d+$/`). For a page that comes late after a click — a form a script checks first, a chain of redirects |
| `waitFor(selector, state, timeout)` | `attached`, `detached`, `visible`, `hidden`; a timeout is an error |
| `click(selector, clickCount)` | Waits for the element, scrolls it into view with the wheel, moves the pointer to a point inside it where it is on top, presses and lets go (2: a real double click); an element covered there is an error naming what covers it |
| `hover(selector)`, `click(at:)` | The pointer over an element; a click at a viewport point |
| `selectOption(selector, choice)` | Chooses in a list (a `<select>`, or its label): an option's value, else its words; `{value}`, `{label}`, `{index}`; a list of them where the list takes several. Gives back the values chosen. The pointer goes to the list; **the choice itself is set from the driver's world**, as AutoFill sets a field — see below |
| `type(selector, text, delay)` | Clicks the field (unless focused), then key after key with Shift held around capitals; a character the keyboard layout has no key for is an error. The log says how many characters, never which |
| `press("Enter" / "Shift+Tab" / "Meta+a")` | A key or a combination, modifier keys pressed before and let go after. The keys with names: Enter, Tab, Backspace, Delete, Escape, Space, the four arrows (`ArrowDown`…), Home, End, PageUp, PageDown |
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

**The one exception: a choice in a list.** A `<select>`'s list is the system's menu, not the page's:
a press on it opens the menu for somebody to choose in, and nothing given to the web view chooses
there. `selectOption` moves the pointer onto the list and then sets the option from the driver's
world, sending the page the `input` and `change` it gets for a person's choice — but those two
events are not marked as a person's (`isTrusted` is false), which a page that looks can see. It is
what WebDriver's click on an `<option>` has done from the start, and what AutoFill does to a
field. A scenario that must not be told apart there has to leave the list to the person.

## What proves it (self-test)

- **"the page cannot tell"**: each trace kind with its fix and without it (docs/PAGE_INPUT.md).
- **"automation commands"**: on pages of the self-test proxy, each command does what it says;
  the page's record of the whole run passes the same rules (trusted events, pointer moves before
  every press, the button held, wheel time and place, focus, keys with Shift, a real double click,
  user activation); the run changes nothing of the fingerprint surface (`fingerprint_probe.js`,
  `navigator.webdriver` false) or the page's globals; `evaluate` in the driver's world is not seen
  by the page, while the same in the page's world — the control — is. After that record is
  taken: `selectOption` chooses by an option's words and by its place, the page hears of it, and
  what cannot be chosen is said; Page Down, Home, End, Page Up and Delete reach the page as a
  keyboard's keys of those names; `waitForLoadState` right after a click on a link whose page
  comes 0.4 s later waits for that page (red on the code before: it read the page being left),
  and `waitForURL` waits for an address and gives up after its time.
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
  profile's own values that the scenario's text names — "A profile's values" below — under what
  an API request gave).
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
- **A run's `params`** (`ScenarioValues.parametersJSON`): of the profile's values, **those the
  scenario's text names** (`ScenarioValues.namesRead`: `params.name`, `params['name']`, in a
  comment too — the recorder's note names `params.password`), each as text — from the editor's
  Run and Check, from a run on many, from a schedule, and from an API request that names a
  **saved** scenario, where what the request gave in `params` wins name by name. A value the text
  does not name is not given, however its code reads `params` (as a whole, `JSON.stringify(params)`;
  by a name it builds, `params[key]`; `eval`): what the import's review, the list and the editor
  say a scenario reads is all of the profile's it gets — a scenario from someone else cannot
  collect the passwords kept for the others. Code that reads `params` that way
  (`ScenarioValues.readsByBuiltNames`) is said on the scenario's line in the list, under its name
  in the editor and in the import's review: "reads values by names its code builds — none given".
  The templates and the recorder name their values. A text sent with the request
  (`{"source": …}`) gets the request's own `params` and no more: what is kept for a profile is
  read by the scenarios the person wrote, not by whatever holds the API's token.
- **In the editor**: the values of the chosen profile open from the button beside the profile's
  name; the names the scenario on screen reads (`ScenarioValues.namesRead`: `params.name`,
  `params['name']`) are offered to fill in, and those the profile has no text for are named under
  the run's bar before the run ("This profile has no value for: password").
- A profile the person deletes takes its values with it (`AppModel.deleteProfile`). The run's log
  never holds a value: typing is logged by its length.

Where a person finds it: **Scenarios is a section of the Profiles window**, beside Profiles and
Proxies (File › Scenarios, ⇧⌘E and ⌘K's command show it), built as those lists are. The automation
settings and Help › Lumen Help (⌘?) open the app's own help (`HelpView`) — how a scenario is made
and run, every command with what it takes, the API's requests, connecting Selenium — in the
interface's language.

## The Scenarios section

Four tabs under the window's header (`ScenariosSection`): **My Scenarios**, **Templates**, **Runs**,
**Schedule**. A scenario opens in place (`ScenarioEditor`), a run's table too (`ScenarioRunTable`).

### Steps

A scenario's text is read as steps (`ScenarioSteps`, BrowserCore). Nothing is parsed into a model and
written back: the text is cut into whole statements — a lossless partition, the pieces joined are the
text byte for byte — and each statement is a step. A one-line command of a known shape
(`await page.click('#buy');`, `await page.type(FIELD, params.login || '');`, `return 'done';` …) is
read for its words; the comment above a statement is the step's name; `for (let i = 0; i < N; i++) {}`
and `if (await page.isVisible(…)) {}` are blocks with steps inside; anything else is a step of its
own code, shown as it is. Moving a step, removing it, switching it off (its lines become comments
marked `//- `) and changing what a command is given are moves and rewrites of whole lines, so what
is not understood is never touched. A text that cannot be cut safely — a bracket or a template left
open — is one step, and the editor says so. Blocks are read for the steps inside them 16 levels deep
at most (`ScenarioSteps.maximumDepth`; steps switched off inside steps switched off count as
levels): one deeper is a step of its own code, and a block of any other shape is not cut again — so
a text nested thousands deep, or one long line, is read in a moment, each line a bounded number of
times.

The `const NAME = value; // what it is` lines at a scenario's head are its **settings**
(`ScenarioSettings`): text, a number, `true`/`false`, or a list of texts. The editor shows them as
fields above the steps and writes a changed one back into its line.

### Templates

`ScenarioTemplate` (BrowserCore): twelve ready scenarios — sign in, check that an account is signed
in, check that a site opens, scroll a feed, search and open results, go through a list of pages, open
a few pages of a site, fill in a form, write and send a text, accept a cookie banner, collect data
from a page, collect a list. Each is a real script of the commands above, written with settings at
its head and a comment over each step; what differs by profile (a login, a password) is read as
`params.<name>`, the profile's own values. No template writes into a page. The Templates tab lists
them by kind and shows the chosen one beside the list — its steps, what it asks for, what it takes
from a profile; **Use the Template** opens its form (the settings as questions, the steps as they
will be on the right), and the scenario made is an ordinary one.

### On many profiles

**Run…** takes the profiles (`ScenarioRunChooser`): search, a tag chooses all that have it; a profile
that has no text for a value the scenario reads is said, and skipped unless asked otherwise; how
many at once (1, 3, 5, 10 — three unless changed), a random pause between starts, and whether the
profiles the run started are stopped again when their scenario has ended.

`ScenarioBatch` (BrowserCore) is the bookkeeping — who waits, who is at work, how each ended —
and `ScenarioBatchCoordinator` (the app) starts each run through `AppModel.runScenario` with a run
id of its own and looks twice a second at how it stands. The table (`ScenarioRunTable`) has a row a
profile: waiting, running, done, **failed at step N** (the step the error's "(line N)" is in) and
why, stopped, skipped and why; how long it took; what the scenario returned. A row opens that
profile's steps (those before the failed one passed) or its log. **Run the Failed Again** makes a
run of those that failed or were stopped; the table is copied as text with tabs or saved as CSV.
The editor's **Check** is a run of one profile, and marks the failed step among the editor's steps.

The runs are kept: `scenario-runs.bin` at the vault's root, sealed under the scenarios' key — the
last 100, newest first; for a profile whose run failed, the last 300 lines of its log; never a
profile's values. A run the app did not see the end of (it quit, the vault was locked) is found as
one that was stopped. This Mac's; not synced. Runs a schedule makes are not among them yet: a
schedule's own row says how its last run ended.

### A scenario as a file

**Export…** writes a `.lumenscenario` file (`ScenarioFile`: JSON with the scenario's name, note and
text — no folder, no schedule, nothing of a profile). **Import a Scenario File…** reads one (at
most 2 MB, refused when it is not one or is a newer version's) and shows, before anything is added,
its steps, the sites its text names and the profile's values it reads: a scenario does in a profile
whatever a person can. The sites are the addresses written out in it (`ScenarioFile.hosts`); when
its code may open others — a `goto` given an address it builds rather than one in quotes or a
setting of its head, code run in the page (`page.evaluate`), `eval` — the review says "and
addresses its code builds" (`ScenarioFile.buildsAddresses`, a reading of the text, not a proof).
The values are those its text names, which is all a run of it is given; code that reads `params`
otherwise is said ("reads values by names its code builds — none given"). The review reads the text
off the main thread (`ScenarioImportReading`) and lists 300 steps at most, counting the others; Add
waits until it has been read.

Checked: `ScenarioStepsTests` (the cut is lossless on every template, a recording and hostile texts;
what is read as which step; each change leaves the other steps as they were; settings read and
written back; every template's form is its head's settings), `ScenarioBatchTests` (the queue and its
limit, ends counted once, Stop, the table as text and CSV, the runs' file, a scenario's file, an
older library); `scripts/test-shims.mjs` runs every template against a page that records what it is
asked. The screens are drawn by the UI snapshots (`scenarios*`).

## Recording

A scenario can be recorded from what a person does (the editor's **Record**; New Scenario ›
Record Actions makes one to record into). While it goes the editor shows the steps in words; at Stop
they become lines after the step chosen in the editor, or at the scenario's end.

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
   Stop Recording ── ScenarioRecording.line(for:) per step, added after the step chosen in the
               editor of the scenario the recording was for (AppModel.recordingScenario), at its
               end when none is chosen — or put in place of the example a scenario written in
               code begins with, while that example is untouched
```

- **The scenario it is for.** A recording belongs to the scenario on screen when Record was
  pressed. Its editor stays until the recording ends; the Scenarios section left and shown
  again shows that scenario, where Stop is; a recording whose scenario was deleted meanwhile is
  ended there, its steps dropped.

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
- **A choice in a list** (`<select>`) is `await page.selectOption(selector, 'value'); // its words`
  — the choice itself, heard as the list's `change`. The click that opened the list is not a
  step: replayed, it opened the system's menu and left it open. Chosen again before anything
  else, the last choice counts; a page that loads after a choice is waited for, as after a click.
  A card's month or year, and a list that takes several choices, stay a comment.
- **Not recorded:** frames, dragging, file uploads, hovering.
- **Only what the person does in a window they see.** A warm-up's pages (its window is in front
  fully transparent) and the page the profile's check measures with are left out. A recording
  ends when its profile stops — its window closed, its process ended — with the lines it has.
- Nothing of the recorder is in a profile's pages before the first recording there. After it the
  script stays, idle: a page's script asks at its start whether a recording is on.

Checked: `ScenarioRecordingTests` (which loads are steps, what typing leaves, a list's choice,
each step's line);
the self-test's "automation commands" (a recording of the driver's own click and typing comes out
as the lines that repeat them, and nothing is recorded after Stop); the page's script against
real input in a browser while it was written (the fields, a password, a checkbox's label, a
button without an id, Enter); `scripts/test-shims.mjs` runs the page's script and the driver's
find on a stub page — secrets, a field and a button in a component's shadow root named
through its host and found there rather than in a look-alike form of the page, a list's choice
said as a step while its click is not, and the driver's own choosing (`PageDriver.chooseOptions`:
by value, by words, by place, what it refuses) — in V8 and in JavaScriptCore.

## By the clock

The section's **Schedule** tab: a scenario, or a
profile's warm-up, every day at a time or every so many hours, with a random shift either way.
**On a Schedule…** in a scenario's ⋯ menu opens the same list with the form filled in for the scenario on
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
                (Enter, Tab, Backspace, Delete, arrows, Home, End, Page Up, Page Down;
                Shift/Control/Alt/Meta of either side held until NULL; the number pad's digits
                and signs as their characters) through WebDriverKeys; text the keyboard's
                layout has no key for is put in as text
       actions ── WebDriverActions (BrowserCore): the client's input sources tick by tick as
                steps of the driver's own pointer, keys and wheel — a move onto an element or
                to a point (a hover), the left button pressed and let go (a click, a double
                click), keys and combinations, the wheel, pauses
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
- **Actions** (Selenium's ActionChains, WebdriverIO's `action`): `move_to_element` — a hover,
  what opens a menu —, `click`, `double_click`, `send_keys`, `key_down`/`key_up` around keys,
  `scroll_to_element`, `scroll_by_amount`, `pause`. The pointer travels to its place as a hand
  moves it whatever duration the client asks, and the button is held as long as a finger holds
  it. **Not among them**, each refused with "unsupported operation" saying which, before
  anything of the request is done: a move with the button held (`drag_and_drop`,
  `click_and_hold`), the right button (`context_click`), a touch or a pen, a click with a
  modifier key held, the wheel sideways. A drag needs events of a kind this input has not been
  measured against a person's (docs/PAGE_INPUT.md), and is left out rather than guessed.
- **Not there:** frames, the page's dialogs (alert, confirm), several windows or tabs in one
  session, file uploads, printing. Each answers with the protocol's own error ("unsupported
  operation", "no such alert").
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
keys as strokes — the keys beside the arrows and the number pad's among them);
`WebDriverActionsTests` (what ActionChains sends for a hover, a click with keys after it, a
double click, the wheel — as the driver's steps — and each thing refused). The page's scripts against a real browser while they were written (finding by
CSS and XPath, an invalid selector, a covered element, an option, clear, a script with elements in
and out, a stale reference). In the full pipeline, `scripts/webdriver_check.sh`: `Lumen
--webdriver-serve` over a temporary vault, and `scripts/webdriver_check.py` with Selenium's own
client — a session starts the profile in a process of its own with Safari's window, opens the
self-test proxy's form, finds the field by CSS, types, finds the button by XPath, clicks, reads
the text; a click made by actions (the pointer moved onto the button, pressed, let go) and keys
typed by actions; then a script with an element, a cookie, a screenshot, the window's size, and quit.
