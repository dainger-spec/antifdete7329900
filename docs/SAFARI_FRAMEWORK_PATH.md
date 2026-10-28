# Safari's own window (experimental `useSafariChrome`)

## Status

Experimental, off by default, per profile: the profile editor's *Safari's own window
(experimental)* toggle (`ProfileConfiguration.useSafariChrome`; configurations without the field
decode as off). Shown and used only in the unsandboxed build. This app's own window
(`BrowserWindowController`, WKWebView) stays the default and the fallback.

## What it does

When a profile with the setting launches, `BrowserSession.openFirstWindow` tries Safari's browser
window from the system Safari.framework before its own:

1. `PBSafariBridge.loadFramework` loads Safari.framework by its install name
   (`/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari`; on macOS 26 it exists only
   in the dyld shared cache).
2. `PBSafariBridge.makeWindowController` asks Safari's `AppController` for a new window
   (`_newWindowWithFrontmostProfile:`, the path of Safari's File > New Window), else makes a
   `BrowserWindowController` directly.
3. The profile's `WKWebsiteDataStore` is offered to Safari's controller (`websiteDataStore`).
4. **Isolation check.** The window is kept only if it has web views and every one uses this
   profile's data store (cookies, storage, the proxy) and its user content controller (fingerprint
   and WebRTC shims, AutoFill, the ping-load blocker). Otherwise it is closed and the usual window
   opens: a Safari window on Safari's own data store would run outside the profile's isolation and
   outside its proxy.
5. A kept window gets the shell look (transparent title bar, floating, on all Spaces), loads the
   start page and is tracked with the profile's windows (closing the last window stops the profile;
   stopping the profile closes it).

The reason for a fallback is logged (`log stream --predicate 'subsystem == "PrivacyBrowser"'`,
category `BrowserSession`) and kept in `BrowserSession.safariChromeFallbackReason`.

## Expected result

Safari's interface is built for Safari's identity (its private entitlements, application and
document controllers, nib and services), which this app cannot have. The SAFARI_GRAPH spike measured
on macOS 15 and 26 (`docs/SAFARI_GRAPH_SPIKE.md` and `SAFARI_GRAPH_SPIKE_V2.md` on branch
`claude/safari-graph-spike`): Safari.framework loads into this kind of process with no entitlement
exception, but `-[BrowserWindowController init]` raises (`NSInvalidArgumentException`, Safari's
`NSDocumentController` internals), and Safari's application start aborts in WebKit during
`-[AppController awakeFromNib]`. No known interface hands Safari's window another data store. So
on the systems measured the path falls back to the usual window; the self-test's *Safari chrome*
checks record the reason on every CI run, and are what to read before relying on this setting.

Measured in CI ([run 275](https://github.com/dainger-spec/antifdete7329900/actions/runs/40788112937),
macOS 26.6.2, Safari 26.6.2, unsandboxed build): Safari.framework loads; `_newWindowWithFrontmostProfile:`
returns nil; `-[BrowserWindowController init]` raises `NSInvalidArgumentException:
-[NSDocumentController frontmostBrowserDocument]: unrecognized selector` (Safari's window controller
expects Safari's own document controller). The exception is caught, the profile opens in the usual
window, no Safari window stays open, and the app's delegate and main menu are unchanged; the whole
self-test passes (186/186 unsandboxed, 187/187 sandboxed, where nothing is tried).

## Safety

- Every call into Safari's code runs in Objective-C inside `@try` (`Sources/SafariBridge`): an
  exception from Safari becomes a fallback reason instead of ending the app, and never unwinds
  through Swift frames. An exception may still leave Safari's half-made objects behind; they hold no
  profile data.
- Nothing process-wide is changed: no swizzled methods, no activation-policy or presentation-option
  changes; the shell look applies to Safari's window only.
- Safari's profile identifiers are not set: they name Safari's own profiles, not this app's.
- The check covers the tabs Safari's window has when it opens. Tabs Safari would make later are not
  checked, one more reason the setting stays experimental.

## Files

- `Sources/SafariBridge/` — Objective-C: loading Safari.framework, making Safari's window controller,
  key-value calls and showing/closing, each inside `@try`.
- `Sources/PrivacyBrowser/Browser/SafariBrowserWindowController.swift` — the isolation check, the shell
  look, the window's lifecycle.
- `BrowserSession.openFirstWindow` — Safari's window or the usual one; `ProfileManager.launch` calls it.
- `SelfTest.safariChrome` — one window either way, no Safari window left open after a failed check,
  the app's delegate and menu unchanged, nothing tried in the sandboxed build.
