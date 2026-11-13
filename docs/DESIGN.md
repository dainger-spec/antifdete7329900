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
  symbol or words beside it. The green state's box ("all in order", the profile check's verdict)
  is `runningTint`/`runningLine`: the same hue as `running`, not a new colour.
- Rows: `rowHover` (white 3.5 %), `rowSelected` (6.5 %).
- Light on raised things, lit from above as the eclipse's rim is: `edgeLit` (a contour, 46 → 32 %
  white, never under `edge` at its foot) and `edgeLitStrong` (64 → 50 %, under the pointer),
  `faceLit`/`faceLitHover` (a raised face, a shade lighter at the top), `pillEdge` (the chosen
  segment's and a key cap's quieter edge), `lipLight` (the 1 pt lit top edge of anything raised),
  `sheetFooterBand` (a sheet's footer, a shade under `raised`). The gradients are computed, not
  stored: a stored gradient may not be Sendable.
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

Titles are semibold, not bold (bold read heavy beside 13 pt text), and tight:
`lumenPageTitle()` (30 pt, −3 %), `lumenDisplayTitle()` (32, −3 %), `lumenHeadingTitle()` (22,
−2.3 %, an inspector's or an editor's name), `Font.lumenSheetTitle` (17 semibold; −0.2 in
`SheetHeader`). Then `Font.lumenRowTitle` (14 medium), `lumenLead` (14, a page's sentence),
`lumenBody` (13), `lumenControl` (12.5 medium, a 28 pt button's or a segment's words),
`lumenSecondary` (12), `lumenMicro` (10.5 medium, chips and "+N"), `lumenCaps()` (11 semibold, +8 %
tracking, capitals, figures of one width: column titles and captions), `lumenMono` (addresses, IPs,
User-Agents).

A paragraph is `lumenProse(_:font:spacing:)`: `t2` by default, lines 2.5 pt apart (2 at 12 pt, 3
for a page's lead), wrapped rather than cut. A grey paragraph of more than a line without room
between its lines reads as a slab.

## Controls

- Buttons: `LumenButtonStyle` — `.lumenPrimary` and `.lumenSecondary` are contours (the main action
  is 32 pt), lit from above: a `faceLit` face, an `edgeLit` contour and a `lipLight` lip; a faint
  light rests under the main button (6 %, 18 % under the pointer), under a secondary one only under
  the pointer. With Increase Contrast they are flat: `edgeStrong`, flat fills, no lip, no light.
  `.lumenGhost` is quiet, `.lumenDestructive` red. Icon buttons: `LumenIconButtonStyle` (`isOn`
  stands raised — `faceLit` and a hairline — e.g. an inspector's toggle). A button beside a 32 pt
  field takes the field's height, so that their edges line up: `.lumenFieldButton` (Check, Apply,
  Add, Icons…). A destructive main action (a sheet's footer) is `LumenButtonStyle(kind:
  .destructive, height: Theme.buttonHeight)`: a red contour; the 28 pt `.lumenDestructive` in rows,
  banners and the selection bar stays quiet.
- Switches and checkboxes: `.lumenSwitch`, `.lumenCheckbox` (a real Toggle underneath for
  VoiceOver). Every contour of a control is at 3 : 1: an off switch is a dark track with the 32 %
  `edge` (50 % with Increase Contrast), and so are an unchecked checkbox's and a radio's rings.
  Segmented choices: `LumenSegmented` — a recessed group (`field`) whose chosen option is a raised
  pill (`faceLit`, `pillEdge`) sliding to the next in 180 ms (it simply appears there under Reduce
  Motion); give it an accessibility label when it has a title. No system segmented controls.
- Fields: `lumenField(...)`, recessed: a faint shadow inside the top edge (not with Increase
  Contrast); search: `LumenSearchField` (with its ⌘K key cap in the windows that have the palette).
  Keys: `KeyCap`, the large one raised (`faceLit`, `pillEdge`). The one field per screen that takes
  the cursor says so: `lumenField(…, takesFocus: true)`, as `LockPasswordField` and
  `AccountTextField` do. No section or sheet of the app's own windows uses the system's grouped
  `Form`: its password fields drew no box at all (the transfer sheets are `EditorField` +
  `lumenField` now).
- A risk said in a sheet before the person acts (a file written in the clear, a profile that will
  be stopped): `SheetWarning` (`SheetChrome.swift`) — the amber tint and line, radius 12, the filled
  triangle, the sentence in `t1`. `LumenBanner` stays for above the list.
- A pane's empty, nothing-found or failed state: `LumenEmptyState` — a light symbol in a 64 pt
  `EclipseRing`, a title, a sentence, an optional quiet note and the action that leads on (the
  Profiles list with nothing found, the profile check's start and failure, What Sites See's first
  run, the scenarios and the schedules — with no profile, New Profile), so that they read alike.
  `LumenEmptyHint` stays for a quiet placeholder inside a panel (an inspector or detail pane with
  nothing selected, an empty log); the empty proxy list, the proxies' nothing-found line and the
  cookie import are still to move to `LumenEmptyState`. The empty Profiles list keeps its own
  (`EmptyProfilesView`): Lumen's glyph in a 72 pt `EclipseRing`, which the state's system symbol
  cannot be. A pane whose empty state has the action does not show it a second time above it: one
  main button (the schedules, the profile check, What Sites See).
- A box that asks for the person: `LumenBanner(tone: .danger | .warning)` above a list (the proxy
  problem, the index notice, kept deleted profiles), the inspector's advice box inside a panel.
  Above the profiles they show one at a time, the most important first; the others wait behind
  "N more" at the first one's end, which opens them in the same order ("collapse" puts them away)
  — so that whoever solves one learns of the next (the owner and the designer, 1 November;
  `ProfilesScreen.bannerStack`). Now: the index, a proxy that does not work, kept folders; the
  licence's banners will take their places by CONTRACT §8.5.

## Elevation — `UI/SheetChrome.swift`

Three levels, each told by light rather than by a heavier shadow:

- The window: `backdrop`.
- A sheet: `lumenSheetSurface()` on its root in place of `.background(Theme.raised)` — `raised`,
  the rim's light at 3.5 % fading out over its top 140 pt, and the presentation itself in the same
  tone, so that no system material shows at its rounded corners. Only a sheet's root (a view
  presented with `.sheet`): never an inline panel, a Settings page or a card. Its footer
  (`SheetFooter`) is a recessed band, `sheetFooterBand`, under its hairline.
- What floats over a list (the selection bar, the command palette):
  `lumenFloatingSurface(cornerRadius:)` — `raised`, a hairline, the `lipLight` top edge, a contact
  and a soft drop shadow.

With Increase Contrast: no glow and no lip, `strongBorder` for the hairline. No Liquid Glass: over
this black it reads as a grey haze and leaves `t2`/`t3` at no known contrast.

## Windows

- Profiles window (`ProfileListView.swift`): sidebar (`ProfilesSidebar`), header (title, count line,
  search, inspector toggle, ⋯, New profile — `ProfilesScreen.headerTop/headerHeight/headerTrailing`,
  which the self-test's clicks use too), the list in three groups, the floating selection bar
  (`ProfileBulkBar`), the inspector (`ProfileInspector.swift`, 320 pt; beside the list when the rows
  keep their columns, over the list — never the header — when not). An inspector's content starts
  under the title bar's band (`ProfilesScreen.inspectorTop`): a scroll view reaching under the title
  bar gets macOS 26's edge effect there, which a window's picture does not draw. In the narrowest
  window the state column narrows first, so that a name keeps its 200 pt. The inspector is the
  80 % frost beside the list (over the light) and opaque `sidebar` black when it lies over the
  list, so that the rows never show through; the floating selection bar keeps to the part of the
  list the inspector leaves visible. A chosen collection or tag is named in the header's count
  line, with how many of all it shows.
- Proxies section (`ProxyListView.swift`, `ProxyInspector.swift`): the same header, the design's
  table (its selected row in the design's tone: the system's highlight is off), the proxy's
  inspector with its check step by step. The inspector over the list is opaque, as the profiles'
  is; the table keeps to the part of the list it leaves visible and, short of room, drops the IP
  first, then the latency, the type and the exit — never the name or the state. A narrow header
  (under 920 pt) drops the total from its count line and shows Check as an icon with its words in
  the help, so that the search keeps its 140 pt.
- Settings (`SettingsView.swift`, `SettingsPages.swift`): sidebar with search and three groups;
  `SettingsPage` (title, sentence, `isNew`), `SettingsCaption`, `SettingRow` (title, what it does,
  when it takes effect, control at the right), `SettingCustomRow` (more than a sentence under the
  title). No section is the system's form: Sync, WebRTC and Automation are pages of rows, and the
  sheets that open them from the Profiles window show the same rows (`embedded`). A page's group
  captions are always `SettingsCaption`, its shortcuts always `KeyCap`; the sidebar scrolls to the
  chosen section (About and Updates were below its fold with nothing selected). A section whose
  title does not fit the sidebar has a shorter name there (`sidebarTitleKey`), the whole title in
  its help.
- Lock and first launch (`VaultViews.swift`): `LockBackdrop`, `LockScreen`, `LockPasswordField` (one
  field per screen takes the cursor: `takesFocus`), the master password's facts first and large,
  `PasswordRequirement`. Changing the master password uses the same fields and requirements.
- Editor (`ProfileEditorForm.swift`): header with the context in capitals, one screen of parts with
  an index.

## Light and motion — `UI/EclipseLight.swift`, `UI/Appearance.swift`

- The eclipse: five blurred circles per corner, geometry per place (`EclipseLight.Place`,
  `EclipseSpec`): the lock screen at full brightness, the profiles window at 55 %, the profile
  editor still at 45 % (`.editor`), Scenarios still at 30 % (`.settings`, the editor's geometry for
  a lower window), the miniature in Settings → Appearance. The Settings window stays plain black:
  its self-test reads its tones row by row. Where a sidebar would hide the light, it is
  `lumenFrost()`.
  Scaled by the window's height; the lock's, in a window narrower than its board (the sign-in
  sheet), by the width, so that its rim never crosses the form.
  Decoration only: hidden from VoiceOver, never in the way of a click; off with Settings →
  Appearance → Lumen's light at entry.
- The eclipse in miniature: `EclipseRing(size:content:)` — a dark disc, a hairline (`strongBorder`
  with Increase Contrast) and light breaking at its top-trailing edge, still. Behind
  `LumenEmptyState`'s symbol (64), the empty Profiles list's glyph (72) and the mark in Settings ›
  About (112). `LumenMark` from 48 pt (the lock and sign-in tile) has a faint halo of the same light.
- Motion (`Motion`): hover at once on and 150 ms off, a press to 98 % in 80 ms, a switch and the
  segmented pill in 180 ms, a selection in 180 ms (`Motion.select`; a row's fill fades in 120 ms), a
  panel in 260 ms (`Motion.panelIn`), the running dot lighting up in 700 ms, groups re-sorting in
  220 ms, entries on the curve (.16, 1, .3, 1). Panels come a short way, not from beyond an edge:
  `AnyTransition.lumenSlide` (a side panel, 24 pt from the trailing edge, not its whole width),
  `.lumenRise` (a floating bar, 10 pt up from 98 %), `.lumenDrop` (a banner, 6 pt down into place).
  With Reduce Motion in macOS, or the animations off in Settings → Appearance, only colour and
  opacity change (`Motion.isReduced`; each transition takes it and is then a fade).
- Live states: `LiveDot(tone:active:)`, a 6 pt dot breathing from 100 to 40 % every 1.6 s while
  something happens now (launching, warming up, encrypting, recording), always beside words that
  say it; a symbol that rotates while syncing and pulses while checking; counts that roll
  (`.numericText()`) when they change. All still under Reduce Motion, with the animations off, and
  in the self-test's still frame (`lumenStillFrame`).
- Density (`AppearancePreferences.density`): rows of 52 or 40 pt.

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
