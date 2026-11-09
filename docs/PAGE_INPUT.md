# The app's own input on a page (`PageInput`)

The warm-up robot, and automation after it, act on a page with a pointer, a wheel and a keyboard
of their own (`Sources/PrivacyBrowser/Browser/PageInput.swift`). The aim: a page cannot tell these
events from a person's mouse and keyboard. Events are made by AppKit and given to the web view in
the profile's process. Nothing is posted to the system's event stream, so the real cursor, the
real keyboard and other apps are left alone, and the window does not need to be in front.

## What a page would otherwise see, and what is done

Measured on macOS 26.7.2 and 27.0.1 against the system's own events (HID, `CGEventPost`), on
branch `claude/measure-automation-input` (rounds 1–5, never merged; probes in
`measure/automation_input/`). A page records every input event with every field
(`isTrusted`, times, client and screen places, buttons, pressure, keys, focus).

| Trace without the fix | Cause | Fix |
|---|---|---|
| No pointer moves before a click; `pointerover` in the same millisecond as `pointerdown` | `WKWebView` takes no `mouseMoved:` of its own. WebKit takes moves only from the owner of its tracking area, which AppKit calls when the real cursor moves | Moves are given to that owner (`trackingAreas`, `owner`, `mouseMoved:`, all public) |
| `buttons` 0 on `mousedown`, `pressure` 0 on `pointerdown` (a real press: 1 and 0.5) | WebKit reads the held buttons from `NSEvent.pressedMouseButtons`, the real mouse's | While this input holds a button, that method answers it |
| Wheel `timeStamp` 0 | A wheel event made from a Quartz event has time 0 | It is given the system's clock (nanoseconds since boot) |
| Wheel at screen 0/768 and at the wrong page point | The event has no window, so WebKit puts it at the screen's corner | `NSEvent.window` answers the web view's window for this event while it is handled; its location is the window's own point |
| `document.hasFocus()` false, first click swallowed, in a window behind another app | WebKit asks the window whether it is the key one; a click given to the window activates it | `holdFocus`: `isKeyWindow` answers true for the held window, and WebKit is told (`NSWindowDidBecomeKeyNotification`); clicks and keys go to the web view itself |

With all fixes, the event log of a run (moves, two clicks, two keys with Shift, three wheel
events) is identical to the HID reference on both systems, with the window in front and with the
window behind another app (round 5, run 42606959269). The one difference left is the system's
autocorrection: real typing of "ab" became "Ab" (an `insertReplacementText`), ours stays "ab", as
for a person with autocorrection off.

The answers are given in the profile's process only, and only for this input's own events and
held windows; everything else gets AppKit's own answers.

## What holding focus touches

- The held window's pages have focus as if it were in front. Another window of the same process
  that is really in front keeps its focus too (pages of two windows cannot see each other's focus).
- WebKit turns on the system's secure keyboard entry while a password field has focus in a key
  window; with a held window that also happens in the background, as in Safari when a password
  field is focused.
- When the hold ends, WebKit is told the window is no longer key, and the page gets `blur`, as
  when a person switches away.

## The warm-up robot

Its window is transparent and lets a person's clicks through, at the floating level. It used to
sit at the lowest level, below the desktop: there the system took it for covered, so its pages
were "hidden" (timers and drawing slowed, which a site can tell) and most pointer moves never
reached them (rounds 6 and 7; the self-test check "warm-up: its pages see themselves shown" was
red on that window, CI 42620678327). Transparent windows at the normal, floating and status-bar
levels stay shown even with an opaque window over them, take every input, and pass a real click
through to the window below (round 7, macOS 26 and 27).

It holds focus on that window for the whole
run, so it now scrolls with wheel events and clicks with pointer moves and mouse events there,
where before it fell back to `scrollBy` and `click()` (the self-test's note line
`warm-up: scrolled with … input` says which). It still falls back when its events do not reach
the page.

## The check: "the page cannot tell" (self-test)

A probe page in a profile window behind another app. One run with every fix, then one run with
each fix left out (`PageInput.fault`); each check passes only when the full run looks like a
person's input **and** the run without its fix shows the trace, so no check can pass while unable
to fail:

- pointer moves before a press (control: moves given to the view);
- the button held on a press (control: no button answer);
- wheel time (control: Quartz time 0);
- wheel place on the page and on the screen (control: no window for the wheel);
- focus, clicks and keys reaching a page behind another app (control: no hold, events to the window);
- every event trusted, and keys with the right `key`, `code`, `keyCode` and Shift around the
  capital (control: the same events made by a page script).

## Not yet measured

- Timing and paths compared with people's (step 7, humanity settings); the owner's one-time
  capture of a real mouse trajectory.
- A web view with toolbar insets (Safari's window): the viewport's top may sit below the view's.
- Real user input at the same moment (the input queue).
- Typing characters the current layout has no key for.
