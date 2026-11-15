# Design: "Eclipse"

The app's own windows follow the design the owner approved on 1 November ("Затмение": dark
monochrome, one light effect, contour buttons). Pages are not themed: they follow macOS, as in
Safari. This page says where each part of the design lives in the code, so that a new screen (the
account and activation screens of licensing, next) is built from the same pieces rather than
restyled later.

## Tokens — `UI/Theme.swift`

- Blacks: `Theme.backdrop` (#08090B, windows), `sidebar` (#0B0C0F, side panels at 80 % over the
  light, `lumenFrost()`), `card` (#111216), `raised` (#121317, sheets and floating bars),
  `raisedInset` (#17181D), `field` (#0D0E11), `avatarFill` (#141519).
- Lines: `divider` (white 6 %), `hairline` (10 %), `strongBorder` (16 %), `edge` (32 %, a button's
  contour, 3 : 1 against the window), `edgeStrong` (50 %, under the pointer and focused).
- Text: `textPrimary` (#F4F4F5), `textSecondary` (#A1A1AA), `textTertiary` (#85858E),
  `textDisabled` (#56565E).
- States: green `running`/`greenDot`, red `danger` with `dangerTint`/`dangerLine`, amber
  `warning` with `warningTint`/`warningLine`. A state is never told by its colour alone: it has a
  symbol or words beside it.
- Rows: `rowHover` (white 3.5 %), `rowSelected` (6.5 %).
- Profiles' colours: the one hue the design keeps outside the states. A profile's glyph is a dark
  circle in its colour with its letters in a light tone of it (`ProfileAvatar.palette`, eight; five of
  them given by an id when the person chose none) — the quickest way to tell profiles apart by eye,
  which the search, the collections and the tags do only through reading or a click (the owner,
  1 November). The colour chosen is kept in the profile's settings as it was.
- Tags' colours: the same eight (owner, 1 November: tags group by meaning, a profile's glyph tells
  apart within a group), told apart from a glyph by their form — a tag's colour is a small dot in
  the palette's light tone (`TagDot`), never a circle with letters. The dot stands in place of "#"
  in the sidebar, before the tag's name in a row's tag line (`TagLine`), in the inspector and on
  the editor's chips. Chosen from the tag's menu in the sidebar (Tag Colour), for the whole vault
  (`TagColors`, `labels.bin`, synced as its own object); a tag without one stays grey.

## Type

`lumenPageTitle()` (30 pt bold, tight), `lumenDisplayTitle()` (32), `lumenHeadingTitle()` (22, an
inspector's or an editor's name), `Font.lumenRowTitle` (14 medium), `lumenBody` (13),
`lumenSecondary` (12), `lumenCaps()` (11 semibold, +8 % tracking, capitals: column titles and
captions), `lumenMono` (addresses, IPs, User-Agents).

## Controls

- Buttons: `LumenButtonStyle` — contours, and one of them leads: `.lumenPrimary` (32 pt, semibold) is lit
  from above — a lighter face toward its top, its contour brighter along the top, a faint light under it;
  `.lumenSecondary` is a quiet contour (16 %); `.lumenGhost` is quiet (Cancel in a sheet, at the main
  button's height), `.lumenDestructive` red; `.lumenFieldButton` beside a 32 pt field. No filled button. Icon buttons: `LumenIconButtonStyle`
  (`isOn` keeps the selected tone, e.g. an inspector's toggle).
- Switches and checkboxes: `.lumenSwitch`, `.lumenCheckbox` (a real Toggle underneath for
  VoiceOver). Segmented choices: `LumenSegmented` — give it an accessibility label when it has a
  title. No system segmented controls.
- Empty states: `LumenEmptyState` — the horizon in small, the title and a sentence above its light, what
  to do under it (the lock screen's order); `small` for a state that passes (nothing found).
- Fields: `lumenField(...)`; search: `LumenSearchField` (with its ⌘K key cap in the windows that
  have the palette). Keys: `KeyCap`.
- A box that asks for the person: `LumenBanner(tone: .danger | .warning)` above a list (the proxy
  problem, the index notice, kept deleted profiles), the inspector's advice box inside a panel.
  Above the profiles they show one at a time, the most important first; the others wait behind
  "N more" at the first one's end, which opens them in the same order ("collapse" puts them away)
  — so that whoever solves one learns of the next (the owner and the designer, 1 November;
  `ProfilesScreen.bannerStack`). Now: the index, a proxy that does not work, kept folders; the
  licence's banners will take their places by CONTRACT §8.5.

## Windows

- Profiles window (`ProfileListView.swift`): sidebar (`ProfilesSidebar`), header (title, count line,
  search, inspector toggle, ⋯, New profile — `ProfilesScreen.headerTop/headerHeight/headerTrailing`,
  which the self-test's clicks use too), the list in three groups, the floating selection bar
  (`ProfileBulkBar`, glass: the rows show through it blurred), the inspector (`ProfileInspector.swift`,
  320 pt): to the window's top beside the list when the rows keep their columns; with less room, beside
  the list under the header, its top-left corner rounded, the list compact (`ProfileColumns.compact`:
  name, the exit as flag and code or its sign alone, state — the row's buttons are the inspector's);
  in the narrowest window over the list, opaque. No row is ever read through it. An inspector's content starts
  under the title bar's band (`ProfilesScreen.inspectorTop`): a scroll view reaching under the title
  bar gets macOS 26's edge effect there, which a window's picture does not draw. In the narrowest
  window the state column narrows first, so that a name keeps its 200 pt.
- Proxies section (`ProxyListView.swift`, `ProxyInspector.swift`): the same header, the design's
  table (its selected row in the design's tone: the system's highlight is off), the proxy's
  inspector with its check step by step.
- Settings (`SettingsView.swift`, `SettingsPages.swift`): sidebar with search and three groups;
  `SettingsPage` (title, sentence, `isNew`), `SettingsCaption`, `SettingRow` (title, what it does,
  when it takes effect, control at the right), `SettingCustomRow` (more than a sentence under the
  title). No section is the system's form: Sync, WebRTC and Automation are pages of rows, and the
  sheets that open them from the Profiles window show the same rows (`embedded`).
- Launch screen (`WelcomeSplash.swift`, `WelcomeGlass.swift`; when: `App/WelcomeLaunch.swift`,
  BrowserCore's `WelcomeSplashPolicy`): before the first screen or the lock screen, in the same
  window, at the first launch and at each start after a full quit — never for a profile's process,
  the self-test, the snapshots, CI's runs or the app's own restarts (Settings › Language, an
  update's installer), nor for a window opened again; off with Settings → Appearance → Greeting at
  launch. The greeting is Pacifico's own outline (`design/fonts/Pacifico`, SIL OFL 1.1; the licence
  ships in `Resources/ThirdPartyNotices.txt`), revealed by a pen moving along its letters in
  1.8–2.4 s, in clear glass lit by the eclipse's horizon (`LumenHorizon`, the virtual machines'
  desktop's): a Metal shader compiled from source as the app starts, Core Graphics masks blurred by
  Metal Performance Shaders, four samples a pixel; where Metal is missing, the outline drawn in
  SwiftUI. Then one light along the greeting, "LUMEN"; the first launch's "Get started", or a
  0.9 s hold; then the opening (0.6 s: the screen eases up 30 pt and fades, the window's content
  scales in from 98 % over it). Any click or key goes on at once. It is shown once, at the first
  launch of an app that has no vault yet (the owner, 15 November: "only at the first launch"), its
  greeting in the interface's language; `open -a Lumen --args --welcome` shows it on any Mac, to
  look at it, each time in the next of twelve languages.
  `design/tools/welcome_lettering.py` makes the outlines, the pen's way (from the outline's skeleton)
  and its pace for the app (`WelcomeLettering.swift`) and the prototype the owner approved
  (`design/prototypes/welcome.html`, the same shader in WebGL; `design/tools/record_welcome.mjs`
  records it).
- Lock and first launch (`VaultViews.swift`), on the launch screen's horizon (the owner, 15 November): the
  Lumen disc without its tile, the title on one line where the window has room and the sentence stand in
  the sky; the horizon's light (`LockHorizon`, `LumenHorizon` with the disc placed) runs 26 pt under the
  sentence; the form is below it, on black. The horizon is a part of the screen's content, so it scrolls
  with the form and never crosses a word; its disc is at least 820 pt in radius, so the rim stays nearly
  level in the 560 pt sign-in sheet. One rule for the unlock, setup, restore and sign-in screens.
  `LockBackdrop`, `LockScreen`, `LockPasswordField` (one
  field per screen takes the cursor: `takesFocus`), the master password's facts first and large,
  `PasswordRequirement`. Changing the master password uses the same fields and requirements.
- Editor (`ProfileEditorForm.swift`): header with the context in capitals, one screen of parts with
  an index.

## Light and motion — `UI/EclipseLight.swift`, `UI/Appearance.swift`

- The eclipse: five blurred circles per corner, geometry per place (`EclipseSpec`): the profiles window at 55 %, editor still, the miniature in Settings → Appearance.
  Decoration only: hidden from VoiceOver, never in the way of a click; off with Settings →
  Appearance → Lumen's light at entry.
- Motion (`Motion`): hover at once on and 150 ms off, a press to 98 % in 80 ms, a switch in 180 ms,
  the running dot lighting up in 700 ms, groups re-sorting in 220 ms, entries on the curve
  (.16, 1, .3, 1). With Reduce Motion in macOS, or the animations off in Settings → Appearance, only
  colour and opacity change (`Motion.isReduced`).
- Density (`AppearancePreferences.density`): rows of 52 or 40 pt.
- A profile's row at 200 profiles: the name semibold; the state's mark in a 14 pt slot of its own (the
  running dot, a ring that fills for a warm-up, the spinner, a lock while encrypting, a red triangle), so
  every state's words start on one edge; tags whole, as many as fit, then "+N"; a row being encrypted is
  not dimmed; a selected row has a hairline round it; the column titles stay above the list as it scrolls.
- A virtual machine's start (`Sources/MachineCover`, shown by the machines' helper): the
  machine's own eclipse, a bead of light gliding along its horizon (6.4 s, then 1.6 s of rest)
  and the haze over it breathing (6 s), "Setting up the machine" in capitals (11 semibold), the
  profile's name (30 semibold), the step (14, `textSecondary`) cross-fading on the entry curve,
  six dashes of 26 × 2 pt; "Show the screen" after a minute; the cover fades into the machine's
  screen in 0.9 s. Approved by the owner on 15 November from `design/prototypes/vm-cover.html`.

- Account (`AccountViews.swift`, docs/LICENSING.md): sign-in and this Mac's connection in the lock
  screen's pieces (`LockScreen`, `LockPasswordField`, `AccountTextField`, `LockActionButton`); Settings
  › Account as rows; the license's banners in `LumenBanner` by CONTRACT §8.5, the ones that stop work
  first; the sidebar's line about the rights (`RightsStatusButton`) between sync and Lock.

## What the design keeps that its pictures do not show

Each of these stays, in the design's own style (the owner, 1 November):

- "Settings cannot be read" instead of "Direct" (R1): in the row, among "Need attention", and in the
  inspector with how to get the settings back; Launch is off for such a profile.
- Deleted profiles whose folders are kept (R3): a banner above the list with Bring back, Remove for
  good, Remove the old folder, Show in Finder.
- "Simplified mode" in a profile's own window when it is not Safari's: the chip in its toolbar, and
  why on a click. Not in an iPhone or iPad view's window, ours by design (the owner, 9 November).
- Files set aside as unreadable (`*.unreadable`): named in every confirmation of a deletion.

## Checked by

The self-test's UI snapshots (`App/UISnapshots.swift`, `--render-ui-snapshots`, in both languages)
draw every screen above, and its clicks go through the transparent title bar to New profile and
Lock by the layout's own numbers.
