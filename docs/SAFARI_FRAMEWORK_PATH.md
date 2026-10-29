# A profile window through the system browser framework

Can this app open a profile's window with the system browser framework's own
`BrowserWindowController` — the real browser chrome, inside our process, on our profile's
`WKWebsiteDataStore` — instead of the `WKWebView` window the app builds itself?

Everything below was measured on GitHub's macOS runners by `scripts/safari_framework/run_probe.py`
driving `PrivacyBrowser --safari-probe <step>`, one step per process, on **macOS 15.7.9 (24G830)**
and **macOS 26.6.2 (25G83)**, arm64, against both the sandboxed and the unsandboxed build
(`.github/workflows/safari-framework.yml`). Results were the same on both OS versions and under
both signatures unless a line says otherwise. SIP is disabled on these runners (§7).

## 1. Answer

**No — not a usable window, on either OS version.** The path gets a long way: the framework
loads, its document controller can be made the process's shared one, its window controller
allocates, its nib loads, and the window's own address-bar view starts laying itself out. It dies
there:

```
*** NSConcreteMutableAttributedString addAttribute:value:range:: nil value
 3  Safari   -[UnifiedField _notSecureAnnotation] + 364
 4  Safari   -[UnifiedField _layOutFaviconAndMainContentView] + 2288
 5  Safari   -[UnifiedField layout] + 56
 6  AppKit   ___NSViewLayout_block_invoke + 632
```

An `NSException` raised inside AppKit's layout pass. Swift cannot catch it, so it ends the
process rather than the attempt — which is why this path runs only when it is asked for on the
command line, and why the in-process `WKWebView` window remains the default and the fallback.

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
first:

| route | result |
|---|---|
| `[[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:NO]`, then `-window` | nib loads, window exists, dies in `-[UnifiedField layout]` (§1) |
| `[[AppController alloc] init]` → `_createNewWindowWithFrontmostProfile:` | dies earlier, in `-[AppController init]` itself (§3) |

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
| `-[BrowserWindowController init]`, `initAsPopupWindow:`, `initWithBrowsingMode:isPopupWindow:` | yes, all three | allocate and return a `BrowserWindowController` |
| `-[BrowserWindowController window]` | yes | loads the nib, then dies in the address bar's layout |
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

Accessory activation policy, borderless, floating, `canJoinAllSpaces`. Applied only after a
window exists *and* a web view was found in it; every earlier return calls `undoShell()`, which
puts the process back to `.regular`. `.accessory` is what removes the Dock tile — the previous
version called `setValue:forKey:` with a `Bool` for `presentationOptions` on the `NSApplication`
*class*, which is wrong in every part and did nothing.

A borderless window also refuses key status unless its class says otherwise, so
`canBecomeKeyWindow` is overridden on the framework's window class when shell mode is applied —
a browser shell that cannot take keystrokes is not a browser. Never reached in these runs.

## 6. Turning it on

- **`-safari-chrome`** (launch argument) — takes the framework path for every profile opened in
  that run, and, because it must, installs the document controller before the app finishes
  launching. Nothing stored changes. **On macOS 15 and 26 this ends the process** at §1; it is an
  opt-in for working on this path, not a feature.
- **`useSafariChrome`** (per profile, default off) — without the launch argument the path stops
  cleanly at the document-controller check and the profile opens in an ordinary window. Safe.
- `PBSafariBootstrapAppController` (default) — also send `applicationDidFinishLaunching:` to the
  framework's application controller. Off; the riskiest call in the sequence.
- `PrivacyBrowser --safari-probe <step>` — one step of the sequence in its own process.
  `scripts/safari_framework/run_probe.py --app <app> --out <dir>` runs them all and collects the
  output, the crash reports and the system log around each.

## 7. How this was measured, and what that is worth

Each step is its own process because reaching into a framework built for another application
crashes rather than returns; a step that dies costs only itself, and the driver records the
signal, the `.ips` crash report and the system log for the step's window.
`NSApplicationCrashOnExceptions` is set, because AppKit otherwise swallows an exception raised
under its run loop and the step hangs with nothing to read — that alone turned four 120-second
timeouts into four backtraces.

**SIP is disabled on GitHub's runners** (`csrutil status`, both). Nothing above depends on it:
`dlopen` of a shared-cache framework, class instantiation and swizzling inside our own process
need no SIP exemption, and the two walls are an AppKit exception and a WebKit identity check,
neither of which SIP enforces. The results should hold on a stock Mac, but they were not
confirmed there.

The runner has no signed-in Apple ID, and the log is full of it (`The user is not signed in with
their Apple ID`, `Failed to get cloud feature eligibility`). None of those are fatal and none are
on the failing path, but a Mac with an account signed in may travel further before failing.

## 8. What is left

- The address-bar layout nil (§1) is one nil in Safari's own UI. Fixing it would most likely move
  the failure to the next thing the framework expects from a process that is Safari — this was
  not pursued, and the stopping point is a judgement, not a proof that no path exists.
- A window controller created without the address bar (`initAsPopupWindow:`) was not tried; a
  popup window has no `UnifiedField`, so it may get past §1. This is the most promising next step
  if the path is picked up again.
- `-[AppController init]`'s extension-controller branch (§3) is a hard stop for that route on any
  process that is not Safari, whatever is done about the UI.
