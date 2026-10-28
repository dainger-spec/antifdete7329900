# Safari.framework in our process (SAFARI_GRAPH spike v2)

Status: second narrow spike. Goal: raise Safari's interface (or get Network Process behavior closer to Safari.app) by bypassing the identity check that aborted v1.

V1 measured (CI runs 261–264, macOS 15 and 26, SIP off):
- `Safari.framework` loads with no entitlement exception.
- `SafariMain()` aborts inside WebKit at `-[WKWebViewConfiguration _setShouldRelaxThirdPartyCookieBlocking:]` during `-[AppController awakeFromNib]` (web extension setup).
- Safari UI requires Safari's identity (168 entitlements, 86 `com.apple.private.*`). A third-party process cannot obtain them (AMFI).
- Network Process for all macOS browsers goes through WebKit, not a separate Safari binary.
- Blackbird loads `Safari.framework` + own frameworks (`BBNativeNoiseSafari`, `BBGeoSafari` etc.) + injected bundle (`BBWebRTCProtect.wkbundle`) + own TURN helper. Their Network Process is a WebKit wrapper, not Safari's.

This spike does not repeat the `SafariMain()` path. It tries to reach a `WKWebView` / window without calling `SafariMain()`, or with the crash on `_setShouldRelaxThirdPartyCookieBlocking:` suppressed.

## 1. Identity checks in Safari / WebKit

Safari and WebKit check process identity in several places before exposing Safari-only behavior:

| Check | Where | What it looks at | Bypass without private entitlements? |
|---|---|---|---|
| Bundle identifier | `+[SafariApplication isSafariApplication]`, various `WBS*` classes | `NSBundle.mainBundle.bundleIdentifier == com.apple.Safari` | No. Hardcoded. Swizzle possible but breaks later assumptions. |
| Parent process | LaunchServices / XPC | Parent is `Safari.app` or `SafariForWebKitDevelopment` | No from inside the process. |
| Entitlements | AMFI, `SecTaskCopyValueForEntitlement` | `com.apple.private.webkit.*`, `com.apple.safari.*` | No. AMFI rejects third-party signatures for these. |
| Sandbox profile | `sandbox_check` | Safari's seatbelt profile | No. Profile is tied to the signed binary. |
| Private selector presence | `WKWebViewConfiguration` category methods | Method responds to selector | Swizzle / category can stub the method, but the caller still expects the side effect. |
| Extension controller | `WBSWebExtensionsController` | Looks up Safari's extension state | Fails without Safari's preference domain and keychain items. |

The crash in v1 is the first of these that is reached when `AppController` wakes. It is not the only one.

## 2. Blackbird's approach (observed, not copied)

Blackbird does not call `SafariMain()`. From the binary layout and runtime behavior:

- It loads `Safari.framework` and `SafariShared.framework` into its own process.
- It injects its own bundle (`BBWebRTCProtect.wkbundle`) into WebKit's WebContent / Network processes via `DYLD_INSERT_LIBRARIES` or `WKProcessPool` configuration.
- It provides its own implementations of several `WBS*` and `Safari*` classes (in `BBNativeNoiseSafari.framework`, `BBGeoSafari.framework`) that short-circuit identity checks and supply the values WebKit expects for noise, geolocation, and media devices.
- It does not run Safari's `AppController` or `BrowserWindowController`. It creates its own `WKWebView` and feeds it a configuration that has already been patched by the injected bundle.
- Network Process behavior (JA4, HTTP/2 SETTINGS, WebRTC ICE) is therefore WebKit's, modified by the injected bundle, not Safari.app's.

This is a sustained reverse-engineering effort against private interfaces. Each Safari release can move the selectors and class layouts. Blackbird maintains it as a product.

## 3. Attempt: suppress the crash and continue

Code in `scripts/safari_graph/probe_v2.m` (off by default, only when `GRAPH_V2=1`):

1. Load `Safari.framework` (same path as v1).
2. Swizzle `-[WKWebViewConfiguration _setShouldRelaxThirdPartyCookieBlocking:]` to a no-op that logs the call and returns.
3. Create an `NSApplication`, set a minimal menu, and instantiate `BrowserWindowController` (or fall back to a plain `WKWebView` if the controller class is absent).
4. If the controller init succeeds, call `showWindow:` and record whether a window appears and whether a `WKWebView` is present in its view tree.
5. Measure Network Process behavior (JA4, HTTP/2 SETTINGS, WebRTC ICE candidate) against a plain `WKWebView` in the same process. If identical, record that the path did not change Network Process identity.

### Expected outcomes

- The swizzle prevents the immediate abort. `AppController` is never created (we do not call `SafariMain()`), so the extension controller path is not entered.
- `BrowserWindowController` init still fails or produces a window that immediately crashes on the next private call (document controller, tab controller, or preference lookup). This is the pattern v1 already saw with the window-controller path.
- A plain `WKWebView` created after the swizzle behaves identically to one created without any Safari.framework load. Network Process fingerprint does not change.

If any of these is wrong on a real Mac, the probe records the difference. The probe does not claim a working Safari UI.

## 4. Verdict

**Identity checks Safari does not bypass without private entitlements.**

The crash on `_setShouldRelaxThirdPartyCookieBlocking:` can be stubbed. That does not produce a Safari window, and it does not make the Network Process look like Safari.app's. Every subsequent Safari class that is reached expects Safari's preference domain, keychain items, or private entitlements. A third-party process can stub individual selectors; it cannot supply the identity those selectors were written to assume.

Blackbird's approach (own frameworks + injected bundle that short-circuits checks and supplies values) is the only path that has been observed to reach a usable window. It is not a one-time patch. It is ongoing maintenance against private interfaces that move with every Safari release.

This spike does not implement that path. It records that the path exists as a product effort, not as a flag in this repository.

## 5. What remains for a real Mac

Run `scripts/safari_graph/probe_v2.m` with `GRAPH_V2=1` on macOS 15 and 26 (SIP off and on). Record:

- Whether the swizzle prevents the abort.
- Whether `BrowserWindowController` init returns a non-nil object.
- Whether a window appears and contains a `WKWebView`.
- JA4 / HTTP/2 SETTINGS / WebRTC ICE of that view versus a plain `WKWebView` in the same process.

If all four are negative, the verdict above stands. If any is positive, update this document with the measurement before changing the main branch.
