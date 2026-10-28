# Safari.framework integration

## Status

Opt-in path added. Existing custom BrowserWindowController remains the default.

## Files

- `Sources/PrivacyBrowser/Browser/SafariLoader.swift` — dlopen Safari.framework at runtime
- `Sources/PrivacyBrowser/Browser/SafariHooks.swift` — swizzle crash-prone methods (empty until selectors known)
- `Sources/PrivacyBrowser/Browser/SafariBrowserWindowController.swift` — wrapper that creates Safari's controller

## Usage

In `BrowserSession.openWindow` the flag `useSafariChrome` (default false) tries the Safari path first. On failure it falls back to the existing custom controller.

## Constraints

- Exact `BrowserWindowController` init signatures and crash-prone selectors must be recovered from live `sample` on BlackBird before the Safari path can be enabled.
- Private entitlements are not required to instantiate the classes; entitlement-gated methods must be swizzled to no-ops.
- All existing tests and the custom chrome path remain functional.
