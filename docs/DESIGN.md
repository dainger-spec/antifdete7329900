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

## Type

`lumenPageTitle()` (30 pt bold, tight), `lumenDisplayTitle()` (32), `lumenHeadingTitle()` (22, an
inspector's or an editor's name), `Font.lumenRowTitle` (14 medium), `lumenBody` (13),
`lumenSecondary` (12), `lumenCaps()` (11 semibold, +8 % tracking, capitals: column titles and
captions), `lumenMono` (addresses, IPs, User-Agents).

## Controls

- Buttons: `LumenButtonStyle` — `.lumenPrimary` and `.lumenSecondary` are contours (the main action
  is 32 pt), `.lumenGhost` is quiet, `.lumenDestructive` red. Icon buttons: `LumenIconButtonStyle`
  (`isOn` keeps the selected tone, e.g. an inspector's toggle).
- Switches and checkboxes: `.lumenSwitch`, `.lumenCheckbox` (a real Toggle underneath for
  VoiceOver). Segmented choices: `LumenSegmented` — give it an accessibility label when it has a
  title. No system segmented controls.
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
  (`ProfileBulkBar`), the inspector (`ProfileInspector.swift`, 320 pt; beside the list when the rows
  keep their columns, over the list — never the header — when not). An inspector's content starts
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
- Lock and first launch (`VaultViews.swift`): `LockBackdrop`, `LockScreen`, `LockPasswordField` (one
  field per screen takes the cursor: `takesFocus`), the master password's facts first and large,
  `PasswordRequirement`. Changing the master password uses the same fields and requirements.
- Editor (`ProfileEditorForm.swift`): header with the context in capitals, one screen of parts with
  an index.

## Light and motion — `UI/EclipseLight.swift`, `UI/Appearance.swift`

- The eclipse: five blurred circles per corner, geometry per place (`EclipseSpec`): lock screen at
  full brightness, profiles window at 55 %, editor still, the miniature in Settings → Appearance.
  Decoration only: hidden from VoiceOver, never in the way of a click; off with Settings →
  Appearance → Lumen's light at entry.
- Motion (`Motion`): hover at once on and 150 ms off, a press to 98 % in 80 ms, a switch in 180 ms,
  the running dot lighting up in 700 ms, groups re-sorting in 220 ms, entries on the curve
  (.16, 1, .3, 1). With Reduce Motion in macOS, or the animations off in Settings → Appearance, only
  colour and opacity change (`Motion.isReduced`).
- Density (`AppearancePreferences.density`): rows of 52 or 40 pt.

## What the design keeps that its pictures do not show

Each of these stays, in the design's own style (the owner, 1 November):

- "Settings cannot be read" instead of "Direct" (R1): in the row, among "Need attention", and in the
  inspector with how to get the settings back; Launch is off for such a profile.
- Deleted profiles whose folders are kept (R3): a banner above the list with Bring back, Remove for
  good, Remove the old folder, Show in Finder.
- "Simplified mode" in a profile's own window when it is not Safari's: the chip in its toolbar, and
  why on a click.
- Files set aside as unreadable (`*.unreadable`): named in every confirmation of a deletion.

## Checked by

The self-test's UI snapshots (`App/UISnapshots.swift`, `--render-ui-snapshots`, in both languages)
draw every screen above, and its clicks go through the transparent title bar to New profile and
Lock by the layout's own numbers.
