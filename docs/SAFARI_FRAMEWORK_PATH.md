# A profile window through the system browser framework

Can this app open a profile's window with the system browser framework's own
`BrowserWindowController` — the real browser chrome, inside our process, on our profile's
`WKWebsiteDataStore` — instead of the `WKWebView` window the app builds itself?

Everything below was measured on GitHub's macOS runners by `scripts/safari_framework/run_probe.py`
driving `PrivacyBrowser --safari-probe <step>`, one step per process, on **macOS 15.7.9 (24G830)**
and **macOS 26.6.2 (25G83)**, arm64, against both the sandboxed and the unsandboxed build
(`.github/workflows/safari-framework.yml`). Results were the same on both OS versions and under
both signatures unless a line says otherwise. SIP is disabled on these runners (§7).

The popup window path (§9) was measured the same way, with the app built against SDK 15.5
(Xcode 16.4) on macOS 15 and SDK 26.5 (Xcode 26.6) on macOS 26, in runs
[40834795505](https://github.com/dainger-spec/antifdete7329900/actions/runs/40834795505),
[40835764560](https://github.com/dainger-spec/antifdete7329900/actions/runs/40835764560),
[40837072147](https://github.com/dainger-spec/antifdete7329900/actions/runs/40837072147),
[40838154367](https://github.com/dainger-spec/antifdete7329900/actions/runs/40838154367),
[40839991411](https://github.com/dainger-spec/antifdete7329900/actions/runs/40839991411) and
[40841056975](https://github.com/dainger-spec/antifdete7329900/actions/runs/40841056975).

## 1. Answer

**No — not a usable window, on either OS version, and not as a popup either.** The path gets a
long way: the framework loads, its document controller can be made the process's shared one, its
window controller allocates, its nib loads, and the window's own address-bar view starts laying
itself out. It dies there:

```
*** NSConcreteMutableAttributedString addAttribute:value:range:: nil value
 3  Safari   -[UnifiedField _notSecureAnnotation] + 364
 4  Safari   -[UnifiedField _layOutFaviconAndMainContentView] + 2288
 5  Safari   -[UnifiedField layout] + 56
 6  AppKit   ___NSViewLayout_block_invoke + 632
```

An `NSException` raised inside AppKit's layout pass. Swift cannot catch it; Objective-C can, and
the path now does, around every call it makes into the framework (§9). What that is worth depends
on the OS. On macOS 15 the exception comes out of `-window`, the attempt ends there, and the
profile falls back to the in-process window, which then loads its page — measured end to end. On
macOS 26 AppKit ends the process from inside its layout pass, whatever
`NSApplicationCrashOnExceptions` says, before the exception reaches anything that could catch it;
the path writes the exception and its stack out the moment it is raised, and that is all it can
do. Either way this path runs only when it is asked for on the command line, and the in-process
`WKWebView` window remains the default and the fallback.

**A popup window is no way round it** (§9). `initAsPopupWindow:` and the variants that get as far
as a window load the same window, with the same toolbar and the same address field, and raise at
the same instruction of `-[BrowserWindowController windowDidLoad]`; the empty-window factory stops
before any window. The popup's own field would not have helped: it is a `UnifiedField` subclass
with the same layout code.

**But the data store question has a yes.** The framework does not take a store as input; it makes
one per profile. Replacing that factory puts the profile's store into the configuration the
framework builds, and the configuration comes back carrying it — measured, §4. So if the UI wall
is ever cleared, the isolation the rest of this app depends on would survive the move.

## 2. The window-creation sequence, as recovered

The framework is opened with `dlopen` and then read with the Objective-C runtime
(`objc_copyClassNamesForImage`, `class_copyMethodList`), so the sequence below is what this macOS
actually declares, not a guess from a sample stack. `SafariLoader` does the reading;
`SafariBrowserWindowController` walks the sequence with a list of candidates per step and records
every nil with its cause.

**Where the framework is.** Not in a cryptex. All four cryptex paths fail with *no such file*;
`/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari` opens, although no file is
there either — dyld resolves it out of the **shared cache**. Opening it pulls in
`SafariFoundation`, `SafariShared`, `SafariSharedUI`, `SafariCore`, `SafariSwift`,
`SafariSafeBrowsing`, `SafariServices` and WebKit. The *bundle* is on disk and holds its
resources: 67 entries, 42 `.lproj`, and its nibs. `Bundle(path:).isLoaded` is `false`, because
dyld mapped the binary without NSBundle.

**Step 0 — the document controller, and why it must come first.** The framework's window path
sends `NSDocumentController` selectors only its own subclass has. Installing that subclass is
possible, but only before the application finishes launching: AppKit creates a plain
`NSDocumentController` on the way up (state restoration asks for the shared one), gives
`+sharedDocumentController` to whichever was created first, and never replaces it. Too late, and
`-[BrowserDocumentController init]` gets AppKit's existing plain instance back out of
`[super init]` and sends it `_commonInit`:

```
-[NSDocumentController _commonInit]: unrecognized selector sent to instance 0x6000007dafc0
```

Measured both ways. Before `NSApplication` exists, `prepareProcess()` reports
`+sharedDocumentController is now BrowserDocumentController`. After the app has launched, the
`documentcontroller-create` step reports `+[BrowserDocumentController sharedDocumentController]
-> nil` and `NSDocumentController.shared is NSDocumentController`. This is what `-safari-chrome`
is for: the per-profile setting alone cannot reach back before launch.

It is also the one irreversible step. Once installed it stays for the run, even if the path then
fails and the app falls back to its own windows.

**Step 1 — the window controller.** Two routes; the direct one gets further, so it is tried
first. With `-safari-chrome` a popup goes before both (§9):

| route | result |
|---|---|
| `[[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:NO]`, then `-window` | nib loads, window exists, dies in `-[UnifiedField layout]` (§1) |
| `[[AppController alloc] init]` → `_createNewWindowWithFrontmostProfile:` | dies earlier, in `-[AppController init]` itself (§3) |
| `[[BrowserWindowController alloc] initAsPopupWindow:YES]`, then `-window` | the same window and toolbar; raises at the same instruction (§9) |
| `+[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:]` | stops before any window, on `-[NSApplication isRestoringWindows]` (§9) |

**Step 2 onward** — `_didCompleteContentSetup`, `showWindow:`, the first tab — are implemented
and wired, and were never reached.

## 3. Selectors: what is there, what answered

| selector | present | result |
|---|---|---|
| `-[AppController _newWindowWithFrontmostProfile:]` | yes | never reached — `-[AppController init]` dies first |
| `-[AppController _createNewWindowWithFrontmostProfile:]` | yes | never reached, same reason |
| `newWindowWithFrontmostProfile:` (no underscore) | **no — no class in the image declares it** | — |
| `+[AppController sharedAppController]` | yes | **returns nil**: there is no instance without the real application having launched |
| `[[AppController alloc] init]` | yes | constructs, then raises (below) |
| `-[BrowserWindowController init]`, `initAsPopupWindow:`, `initWithBrowsingMode:isPopupWindow:` | yes, all three | allocate and return a `BrowserWindowController`; made as a popup, it reports `isPopupWindow` YES |
| `-[BrowserWindowController isPopupWindowUnifiedFieldVisible]`, `setPopupWindowUnifiedFieldVisible:` | yes | NO on a new popup already; setting NO changes nothing (§9) |
| `+[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:]` | yes | makes a document, asks the store factory for the profile, then raises `-[NSApplication isRestoringWindows]: unrecognized selector` (§9) |
| `-[BrowserWindowController window]` | yes | loads the nib, then dies in the address bar's layout — the popup's too |
| `-[BrowserWindowController unifiedField]` | yes | after that raise: the toolbar's field, in no window yet (§9) |
| `-[BrowserWindowController makeBrowserViewControllerInTabAtIndex:andSelect:]` | yes | not reached |
| `-[BrowserWindowController showWindow:]` | yes | not reached |
| `-[BrowserWindowController _didCompleteContentSetup]` | yes | not reached |
| `+[BrowserDocumentController sharedDocumentController]` | yes | the instance before launch; **nil** after |
| `+[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:]` | yes | **works** — see §4 |

`-[AppController init]` builds its web-extension controllers eagerly, and that branch is stopped
by WebKit on identity:

```
*** _shouldRelaxThirdPartyCookieBlocking may only be used by Safari.
 3  WebKit          -[WKWebViewConfiguration(WKPrivate) _setShouldRelaxThirdPartyCookieBlocking:] + 152
 4  Safari          +[WebKitPreferencesManager webExtensionWebViewConfigurationForExtensionsController:relatedWebView:] + 404
 5  SafariSharedUI  -[WBSWebExtensionsController initializeWebKitControllerIfNeededFromSettings:] + 220
 6  Safari          -[AppController _createExtensionControllersIfNeededForProfileServerID:] + 356
 7  Safari          -[AppController webExtensionsControllerForProfileServerID:] + 88
```

WebKit refuses by bundle identifier, so no amount of further setup inside the framework answers
it. Note what it is *not*: it is on the **web-extensions** configuration, not on the ordinary
content one, which is why avoiding `AppController` avoids it entirely.

## 4. The data store, and the key that binds it

**There is nowhere to put a store after the fact.** `-[WKWebView configuration]` returns a copy,
so assigning `websiteDataStore` to it once the view exists changes nothing a page will ever see:
WebKit reads the store when the page is created and never looks again. The earlier version of
this path set the store by KVC on the *window controller* instead
(`setValue:forKey:"websiteDataStore"`), which `BrowserWindowController` does not declare at all —
it has no selector matching `datastore` in its 1420 — so that would have raised
`setValue:forUndefinedKey:` had it ever run.

**Nor is there a configuration of ours to put a store into.** The framework builds its own, and
does not accept one. It *makes* a store, from the profile identifier:

```
+[WKWebsiteDataStore(SafariSharedExtras) _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
+[WKWebsiteDataStore(SafariSharedExtras) _newDataStoreForProfileIdentifier:]
-[_WKWebsiteDataStoreConfiguration initWithIdentifier:]
```

(Found because calling the configuration factory with a nil identifier raises `Identifier is nil`
from that last frame.)

**The working key** is therefore that factory, and `SafariHooks` replaces it for the span of one
window's creation — a class method, so the override goes on the metaclass:

```
+[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
```

`-[WKWebViewConfiguration websiteDataStore]` is overridden too, as a second line for anything
that reads a store without going through the factory. A plain getter and a class factory are also
the safe things to replace: an `init`-family method returns +1 where a block returns +0, and a
swizzle across that line miscounts the object.

**Does the store match the profile?** Yes, measured end to end, on both OS versions:

```
calling +[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:…]
  -> WKWebViewConfiguration
  websiteDataStore: persistent CF5908DC-608F-443D-8ED0-9E76B057C266      # the identifier passed in
with the profile's store bound:
  per-profile store factory asked for E62DCEDC-… -> handed it non-persistent
  websiteDataStore is the bound one: true
```

Unbound, the framework returns a store of its own keyed by the profile identifier it was given.
Bound, the configuration comes back carrying **our** store object. That is the whole of what item
2 asked for, and it holds independently of whether a window ever appears.

**What the web view's class is: not established.** No web view was ever created, because the
window died in layout first. The classes that own a store on the framework's side are
`WebViewController` and `SearchableWKView` (both declare `websiteDataStore`); the view in a tab
is built by `-[BrowserWindowController makeBrowserViewControllerInTabAtIndex:configuration:andSelect:]`.
Recording this as unknown rather than guessing from the class list.

## 5. Shell mode

Accessory activation policy, borderless, floating, `canJoinAllSpaces`. The ordinary window applies
it only after a window exists *and* a web view was found in it; the popup path (§9) applies it as
soon as its window has loaded and shown, before its tab is opened, and takes it back if the tab or
the web view then fails. Every failure calls `undoShell()`, which puts the process back to
`.regular`. `.accessory` is what removes the Dock tile — the previous version called
`setValue:forKey:` with a `Bool` for `presentationOptions` on the `NSApplication` *class*, which is
wrong in every part and did nothing.

A borderless window also refuses key status unless its class says otherwise, so
`canBecomeKeyWindow` is overridden on the framework's window class when shell mode is applied —
a browser shell that cannot take keystrokes is not a browser. Never reached in these runs.

## 6. Turning it on

- **`-safari-chrome`** (launch argument) — takes the framework path for every profile opened in
  that run: a popup first (`initAsPopupWindow:YES`, §9), then the ordinary window. Because it
  must, it installs the document controller before the app finishes launching. Nothing stored
  changes. **On macOS 15 both windows raise, both raises are caught, and the profile opens in the
  in-process window; on macOS 26 the popup's raise ends the process** (§9). It is an opt-in for
  working on this path, not a feature.
- **`useSafariChrome`** (per profile, default off) — without the launch argument the path stops
  cleanly at the document-controller check and the profile opens in an ordinary window. Safe.
- `PBSafariBootstrapAppController` (default) — also send `applicationDidFinishLaunching:` to the
  framework's application controller. Off; the riskiest call in the sequence.
- `PrivacyBrowser --safari-probe <step>` — one step of the sequence in its own process.
  `scripts/safari_framework/run_probe.py --app <app> --out <dir>` runs them all and collects the
  output, the crash reports and the system log around each. The popup steps are `popupfield`,
  `popup`, `popup-nofield`, `popup-mode` and `popup-hidden`; `popup:crash-off` and `window:chrome`
  run a step again under other launch arguments (`VARIANT_ARGUMENTS` in the driver).

## 7. How this was measured, and what that is worth

Each step is its own process because reaching into a framework built for another application
crashes rather than returns; a step that dies costs only itself, and the driver records the
signal, the `.ips` crash report and the system log for the step's window.
`NSApplicationCrashOnExceptions` is set, because AppKit otherwise swallows an exception raised
under its run loop and the step hangs with nothing to read — that alone turned four 120-second
timeouts into four backtraces.

The popup steps are the exception. They run as the app does, without
`NSApplicationCrashOnExceptions`, because whether a raise can be caught is what they measure
(`popup:crash-off` sets it to NO, to tell off from unset). Nothing is lost to a hang for it:
`Sources/ExceptionCatcher` installs an Objective-C exception preprocessor, which the runtime calls
for every exception before any handler sees it, AppKit's included, and the path writes each one
out there with its stack. That is how the macOS 26 stacks in §9 were read out of processes AppKit
then ended. Every step that ends without a framework window then opens the plain web view window
the app falls back to and loads a page in it, so a catch that left the process unable to carry on
would show. Crash reports are matched to their step by process id: macOS writes them late,
sometimes after the next step has begun.

**SIP is disabled on GitHub's runners** (`csrutil status`, both). Nothing above depends on it:
`dlopen` of a shared-cache framework, class instantiation and swizzling inside our own process
need no SIP exemption, and the two walls are an AppKit exception and a WebKit identity check,
neither of which SIP enforces. The results should hold on a stock Mac, but they were not
confirmed there.

The runner has no signed-in Apple ID, and the log is full of it (`The user is not signed in with
their Apple ID`, `Failed to get cloud feature eligibility`). None of those are fatal and none are
on the failing path, but a Mac with an account signed in may travel further before failing.

## 8. What is left

- The address-bar layout nil (§1) is one nil in the framework's own UI, and §9 makes it the one
  thing in the way of every window route tried: the popup lays out the same field from the same
  instruction. Fixing it would most likely move the failure to the next thing the framework
  expects from a process that is the system browser — this was not pursued, and the stopping
  point is a judgement, not a proof that no path exists.
- The popup lead is closed (§9). No popup variant gets a window without a `UnifiedField`: the
  toolbar's field is built and laid out whatever the popup flag says, and the popup's own field is
  the same class underneath. `+openEmptyBrowserWindowController` and its profile and test
  siblings were not tried; they are not popups.
- `+hiddenEmptyBrowserWindowController…` stops on `-[NSApplication isRestoringWindows]`, a method
  of the framework's own application class. Answering it would be the same kind of step as
  installing the document controller (§2); not pursued — it makes the same window controller
  class, whose `-windowDidLoad` is where §1 raises.
- On macOS 26 a raise inside the layout pass ends the process whatever
  `NSApplicationCrashOnExceptions` says (§9). Whether that follows the OS or the SDK the app is
  built with (26.5 there, 15.5 on the macOS 15 runner) was not measured.
- Sandboxed, the framework is denied its tab-group sync agent, and twice in these runs its proxy
  then ended the process from a background queue (§9). Keeping it from starting that work was not
  pursued.
- `-[AppController init]`'s extension-controller branch (§3) is a hard stop for that route on any
  process that is not Safari, whatever is done about the UI.

## 9. The popup window path

The lead §8 left: a window controller made as a popup, in case its window is laid out without the
toolbar's `UnifiedField`. `SafariBrowserWindowController.openPopup` creates the controller, loads
its window (`-window`), shows it (`showWindow:`), applies shell mode (§5), opens its tab and finds
its web view — all of that inside the data store binding of §4 — then compares that view's store
with the profile's. Every call into the framework is inside an Objective-C `@try`
(`PBCatchException`, `Sources/ExceptionCatcher`); every exception raised meanwhile is written out
as it is raised, with its stack, and any one of them ends the attempt. `-safari-chrome` runs it
before the ordinary window.

### Which selectors were tried

| probe step | call | macOS 15.7.9 | macOS 26.6.2 |
|---|---|---|---|
| `popup` | `[[BrowserWindowController alloc] initAsPopupWindow:YES]`, then `-window` | a controller, `isPopupWindow` YES; `-window` raises in `-[UnifiedField layout]`; caught | the same raise; the process ends (SIGTRAP) |
| `popup-nofield` | the same, with `setPopupWindowUnifiedFieldVisible:NO` before `-window` | the property was NO already; the same raise; caught | the same; SIGTRAP |
| `popup-mode` | `[[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]`, then `-window` | as `popup` | as `popup` |
| `popup-hidden` | `+[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:0 profileIdentifier:<profile> isPopupWindow:YES]` | raises `-[NSApplication isRestoringWindows]: unrecognized selector` before any window; caught | the same; caught |
| `popup:crash-off` | `popup`, with `-NSApplicationCrashOnExceptions NO` | as `popup` | as `popup`: SIGTRAP |
| `window:chrome` | the app's own path under `-safari-chrome`: `popup`, then the ordinary window | both raise, both are caught, the in-process window loads its page | the popup's raise ends the process |

The same under both signatures. `-safari-chrome` runs the first variant only: each of the others
builds another window that fails the same way, and a run of all four ahead of the ordinary window
ended worse — see the end of this section.

### Did a window appear?

No. On macOS 15 a window object exists — `-window` loaded the nib before `-windowDidLoad`
raised — but it was never shown, so shell mode was never applied and no tab was opened. It holds
a visible `BrowserToolbar` whose `NSToolbarView` has no item in it yet, no title-bar accessory, and
no `UnifiedField` anywhere in its view tree. The one address field the controller holds is the
toolbar's own, asked for once the raise was caught:

```
-unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
_popupWindowUnifiedField -> nil
```

So the field that raises is the toolbar's, laid out by `-windowDidLoad` before it is in the
window, popup or not: the raise comes from the same return address as the ordinary window's,
`windowDidLoad + 1068` on macOS 15 and `+ 1032` on macOS 26. Turning the popup's own field off
could not have helped — it had not been made when the window raised,
`isPopupWindowUnifiedFieldVisible` is NO on a new popup already, and `popupfield` shows the field
would lay out the same way, on both OS versions:

```
PopupWindowUnifiedField <- UnifiedField <- NSTextField <- NSControl <- NSView <- NSResponder <- NSObject
  -_notSecureAnnotation: inherited, UnifiedField's own implementation
  -_layOutFaviconAndMainContentView: inherited, UnifiedField's own implementation
  -layout: inherited, UnifiedField's own implementation
```

On macOS 26 the window cannot be looked at: the process does not live past the raise.

### Did the data store match?

Not reached: there was never a web view to compare. A popup's tab is opened after its window
loads, and the profile's store was handed out 0 times during the attempt (macOS 15; on macOS 26
the process ends first). `popup-hidden` gets further into the framework before it stops — far
enough to build the configuration for a tab — and there the binding of §4 holds: the framework
asked the store factory for the profile's own identifier and was handed the profile's store
object, on both OS versions:

```
per-profile store factory asked for 41EC8113-… -> handed it persistent 41EC8113-…
per-profile store factory asked for 41EC8113-… -> handed it persistent 41EC8113-…
websiteDataStore read on WKWebViewConfiguration -> persistent 41EC8113-…
```

That shows the binding reaches this path too. It does not show a page loading into the profile's
store, which only a web view could.

### The exact failure

macOS 15.7.9, `popup` — the exception of §1, from `-[BrowserWindowController windowDidLoad]`,
recorded as it was raised:

```
NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
 0  CoreFoundation   __exceptionPreprocess + 176
 1  PrivacyBrowser   PBPreprocessException + 52
 2  libobjc.A.dylib  objc_exception_throw + 88
 3  Foundation       -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
 4  Safari           -[UnifiedField _notSecureAnnotation] + 364
 5  Safari           -[UnifiedField _layOutFaviconAndMainContentView] + 2288
 6  Safari           -[UnifiedField layout] + 56
 7  AppKit           ___NSViewLayout_block_invoke + 632
 8  AppKit           NSPerformVisuallyAtomicChange + 108
 9  AppKit           _NSViewLayout + 96
    …
17  AppKit           -[NSView layoutSubtreeIfNeeded] + 96
18  Safari           -[BrowserWindowController windowDidLoad] + 1068
19  AppKit           -[NSWindowController _windowDidLoad] + 620
20  Safari           -[WindowController _windowDidLoad] + 52
21  AppKit           -[NSWindowController window] + 100
22  PrivacyBrowser   ObjCRuntime.callReturningObject(_:_:)
```

It comes out of `-window` and `PBCatchException` catches it.

macOS 26.6.2, `popup` — the same exception, from `windowDidLoad + 1032`. AppKit catches it inside
the layout pass and ends the process there; the crash report's triggered thread:

```
0  AppKit  +[NSApplication _crashOnException:] + 256
1  AppKit  +5413880
2  AppKit  +5414380
3  AppKit  ___NSViewLayout_block_invoke + 624
4  AppKit  NSPerformVisuallyAtomicChange + 128
5  AppKit  _NSViewLayout + 96
```

`NSApplicationCrashOnExceptions` read false at every stage of these runs — unset everywhere for
`popup`, NO in the arguments domain for `popup:crash-off`, never registered by the framework — and
the process ended all the same.

`popup-hidden`, both OS versions:

```
NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x…
 6  Safari  -[BrowserDocument makeWindowControllers] + 168
 7  Safari  -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 144
 8  Safari  -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 232
 9  Safari  -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
10  Safari  +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
11  Safari  +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
```

Not in a layout pass, so it is caught on macOS 26 as well.

### Is it caught, and does the process carry on?

**macOS 15: yes.** Getting there took one more thing. A window whose `-windowDidLoad` raised still
needs layout, and closing it does not take it out of AppKit's display cycle: in run 40837072147
the next cycle laid its toolbar out again, and the field raised outside any guard —

```
 6  Safari  -[UnifiedField layout] + 56
    …
31  AppKit  -[NSToolbarItemViewer _layoutSubtreeWithOldSize:] + 52
    …
38  AppKit  -[NSToolbarView _computeToolbarItemKeyboardLoop] + 572
39  AppKit  -[NSToolbarView _layoutDirtyItemViewersAndTileToolbar] + 2904
40  AppKit  -[NSToolbarView layout] + 76
    …
62  AppKit  -[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded] + 240
63  AppKit  __NSWindowGetDisplayCycleObserverForLayout_block_invoke + 364
    …
65  AppKit  NSDisplayCycleFlush + 656
    …
68  AppKit  __62+[CATransaction(NSCATransaction) NS_setFlushesWithDisplayLink]_block_invoke + 272
```

— and the flush handler ended the process (`+[NSApplication _crashOnException:]`), with
`NSApplicationCrashOnExceptions` unset. A failed window is now retired with its toolbar detached
before it is closed, so its field is in no window and nothing lays it out again. After that, in
run 40838154367:

| macOS 15.7.9, both signatures | outcome | the in-process window afterwards |
|---|---|---|
| `popup` | raise caught, exit 0 | loads `https://example.com/`, title "Example Domain" |
| `window:chrome` | both raises caught, exit 0 | the same |
| `window` — the ordinary window alone, `NSApplicationCrashOnExceptions` on | raise caught, exit 0 | loads `https://example.com/` (its title not yet set when read; the snapshot shows the page) |

The in-process window here is a plain web view window on the profile's store, standing in for the
app's own; its snapshots are in the results branch (`unsandboxed/<step>/fallback-page.png`).

**macOS 26: no.** AppKit ends the process inside the layout pass, as above. It does not end
silently — the exception and its stack are written out as it is raised, before AppKit acts on it,
by the app through `NSLog` as much as by the probe — but nothing in the process can stop it. Only
`popup-hidden`'s raise, which is not in a layout pass, is caught there, and the in-process window
then loads its page.

**Sandboxed, one more way to end.** Twice the sandboxed build on macOS 15 ended before `-window`
was even sent, on a thread of the framework's own. The `popup` step in run 40839991411:

```
objc[3210]: Cannot form weak reference to instance (0x600002a30a00) of class NSXPCConnection. It is possible that this object was over-released, or is in the process of deallocation.
 4  libobjc.A.dylib  _objc_fatal(char const*, ...)
 5  libobjc.A.dylib  weak_register_no_lock
 6  libobjc.A.dylib  objc_storeWeak
 7  Foundation       -[NSXPCConnection _sendInvocation:orArguments:count:methodSignature:selector:withProxy:]
    …
10  WebBookmarks     __44-[WBTabGroupSyncAgentProxy addSyncObserver:]_block_invoke
    …   queue com.apple.WebBookmarks.WBTabGroupSyncAgentProxy.…._syncObserverQueue
```

And the `popup-nofield` step in run 40841056975, the run of the commit that added this section,
from the same block:

```
EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000782df1450fc0
 0  libobjc.A.dylib  objc_retain
 1  Foundation       -[_NSXPCDistantObject _initWithConnection:proxyNumber:generationCount:interface:options:error:]
 2  Foundation       -[NSXPCConnection remoteObjectProxy]
 3  WebBookmarks     __44-[WBTabGroupSyncAgentProxy addSyncObserver:]_block_invoke
    …   queue com.apple.WebBookmarks.WBTabGroupSyncAgentProxy.…._syncObserverQueue
```

The App Sandbox denies the framework its tab-group sync agent (`deny(1) mach-lookup
com.apple.SafariBookmarksSyncAgent`, in the sandboxed steps' logs and in none of the unsandboxed
ones); the framework logs `Connection to TabGroups sync agent was invalidated`, and its proxy, on
its own queue, goes on using the connection as it goes away — an abort in the Objective-C runtime
one time, a bad access the next. Neither is an exception, so nothing can catch them. Two
sandboxed steps in six runs, a different one each time, and never unsandboxed: a race, and the
sandboxed build can lose it.

**Running every variant first.** In run 40837072147 `window:chrome` tried all four variants
before the ordinary window, on macOS 15. All four raises were caught; then the ordinary window's
`-windowDidLoad` took another turn — it set up a background tab — and the framework aborted on an
assertion, which no `@try` catches:

```
ASSERTION FAILURE: "sharedSearchEngineObserver" in +[WBSSearchEnginePreferenceObserver sharedObserver], WBSSearchEnginePreferenceObserver.m:60
 2  libsystem_c  abort + 124
 3  SafariCore   +[WBSSearchEnginePreferenceObserver sharedObserver].cold.1 + 356
 4  SafariCore   +[WBSSearchEnginePreferenceObserver sharedObserver] + 44
 5  SafariCore   +[WBSFeatureAvailability defaultSearchEngineMatchesExperiment] + 28
 6  Safari       -[BrowserViewController searchURLWithTrialGroupIdentifier:] + 52
 7  Safari       -[BrowserViewController expectedURL] + 216
    …
10  Safari       -[BrowserTabViewItem setTabContentViewController:] + 188
    …
13  Safari       -[BrowserWindowController _setUpBackgroundTabAfterLastTabWithBrowserViewController:] + 60
14  Safari       -[BrowserWindowController windowDidLoad] + 908
```

With the popup initialiser alone ahead of it, the ordinary window does not take that turn.
`popup-hidden` is the only variant that gets as far as a tab, so it is the likely source, though no
run isolated it — and it is why `-safari-chrome` tries the first variant only.
