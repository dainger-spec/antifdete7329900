# Safari's menu bar in a profile's process, item by item

A profile shown in Safari's own window runs Safari's chrome inside a process of ours
(`SafariChromeHost`, docs/SAFARI_PROCESS.md §9). Safari's menu bar comes with it, and every one of
its items is code written for Safari.app — with Safari's services, its containers, its databases —
running somewhere it was never meant to run. The owner went through the menus by hand and found
three crashes in an evening. This page is the machine doing the same, every item, on every CI run:
what each item does in a profile, where it writes, which services it starts, and what is decided
about it.

## How it is walked

`scripts/menu_walk.py` runs `PrivacyBrowser --menu-walk` (`SafariMenuWalkCheck`): a new profile
in a temporary vault, launched as the app launches one — a process of its own, Safari's window,
held to the self-test proxy (its start page, a login form, loads through it). The profile is
asked over its channel to walk its menu (`ProfileCommand.walkMenu`, `SafariMenuWalk`); nothing
of the walk exists in a profile's process until that command comes, and only this check sends it.

For each item, in menu order, depth first (the menus Safari fills as they open — History,
Bookmarks, Window — are filled first):

1. a browser window of the profile is brought to the front (opened again if the last item
   closed it), showing the page the walk began on (loaded again if an item before left another
   tab or page in front: every item is chosen on a page, as a user mostly chooses it);
2. the menu validates the item as opening it would; a disabled item is said to be so and is not
   chosen;
3. the item is chosen with `-[NSMenu performActionForItemAtIndex:]`, as a click does;
4. a moment later, what changed is told: windows and sheets that opened or closed (by class and
   title), the key window, its first responder, its page and zoom, whether the app hid;
5. what the item asked for and the walk answered instead of letting it happen: a save, open or
   print panel (Cancel), an alert (its cancel button), a window run modally (ended), a URL or an
   application to open, the Finder, a sharing service, Help, the character viewer, hiding the
   other applications, quitting (none of them done) — and our own notices;
6. every exception thrown meanwhile, by name, reason (cut as the log cuts it) and first frames;
7. from outside the process: the XPC services that started for it and what they held open in
   the real Safari's places, Safari's other processes that started meanwhile (its agents and
   extensions, whoever asked for them), and the files written while it ran — in the profile's
   vault and home, in the real Safari's places, anywhere else in the account's home (minus
   macOS's own records of what any application does, such as Biome's record of menu use);
   and, for the walk as a whole, the real Safari's own preferences read before and after
   (`defaults export com.apple.Safari`, with sentinels set first on CI's runners): cfprefsd writes
   them for whichever process asks, which the file trace cannot say (it names what cfprefsd
   writes, through the directory descriptors it follows, since 1 November);
8. then back to where it began: what it opened is closed, the app shown, nothing minimized or
   full screen. Toggles an item made (a hidden toolbar, a zoom) stay for the items after it.

After the menu, the actions of the items that are kept out of it — AutoFill's, and those whose work
is done outside the profile — are sent straight to the first responder, as a key or another menu
would send them.

An item that ends the process is a crash: its crash report is attached, the profile is started
again (its home sealed and opened as at any launch), and the walk goes on from the next item. An
item that answers nothing for 25 seconds is a hang; its process is killed.

Not chosen: the system's Services (they hand the selection to other applications; `HandOffs`
keeps them from pages) and items that are views rather than commands.

## The record, and the check

The walk's items are paired with the record's by what they do, never by their titles: Safari builds
its menus in the system's language, and on the owner's Mac, in Russian, 90 items came or went by
title while 144 of 147 did the same as their record (1 November). An item is paired by its action and
keys; what is left, by an action only one item has on each side (or one item Safari lists twice).
An item paired by its action alone has keys of this Mac's — Start Dictation…'s second key is a
MacBook's dictation key, Close Other Tabs has ⌥⌘W on some Macs and runners and no keys on others —
and is said, not failed on. The summary line says how many recorded items did the same, how many under
this Mac's keys and how many under other titles.

Each item is reduced to what is compared: what it did, without what follows timing (whether the
window changed or nothing was seen in the moment after it, a window AppKit makes for a moment,
AppKit's own layout exception: runs 463 and 468 read those differently for the same items; and
whether Stop Speaking and Start Dictation… were enabled, which follows the system's state — the
speech an item before started, the system's dictation: runs 470, 471 and 474), and the XPC services
it started. `docs/menu-walk/safari-<major>.json` keeps that
reduction for each Safari, from the walk CI made where it checks it (run 471, the commit that
brought the walk: its jobs walk after the self-test and the other checks). The measurement branch's
walks, each on a fresh runner, read the same for every item but one, in all four of them (runs 468
and 470, twice each): there File › Print… brought another application forward (the system's
notification center). CI walks the menu
on every run, in both macOS jobs, and with `--check`:

- **fails** when the walk does not get to the end, when an item does something else than its
  record says (a crash or a hang, a new exception, a panel, an alert or a request to open
  something that was not there, our notice gone), when `fs_usage` puts a write in the real
  Safari's places on the profile (the app's and WebKit's processes), when the trace does not name
  cfprefsd's write of a canary preferences file made as the walk begins (the trace would be blind
  to cfprefsd again), or when the profile's process asked more than a thousand times for a view
  whose service it is refused (the loop below);
- **says**, without failing, which items came or went — which items a menu has follows the
  window's state and, on Safari 27, the runner — which were paired by their action under this
  Mac's keys, what cfprefsd wrote in the real Safari's places (for a process the trace cannot
  name), and what FSEvents saw written there by any process (macOS's own daemons and Safari's
  agents write there on their own).

On macOS 26 a failure fails the build; on macOS 27 it is reported (that job fails the build only on
a certificate fetched for outside a profile's proxy). A
Safari with no record (a new major version) is walked and its record written into the run's
`menu-walk` artifact, to be looked at and committed. A change that is meant is recorded again
(`--write-record`), with the reason in the commit.

## What the walk found, and what was done

Measured on GitHub's runners, Safari 26.6.2 (macOS 26.6.2) and Safari 27.0.1 (macOS 27.0.1): 148
items walked on each, every one chosen on the page, in one launch each (CI run 468, on the
measurement branch: this walk, which there also chose Window › Full Screen Tile's two items; earlier
runs as named). Since the items whose work is done outside the profile were taken out, 147 on each
(the table: run 520).

**Fixed** (each with the walk as its proof):

- **Edit › AutoFill › Contact… / Passwords… / Credit Card…** (run 452). AppKit adds these system
  items to any Edit menu once the menu bar is up, after `installMainMenu` had removed them, and in a
  profile's window they were enabled: on macOS 26, Passwords… had Safari's helper
  (SafariPlatformSupport) write into the real Safari's container (`com.apple.Safari.plist`,
  `AutoFillQuirks.plist`) and `~/Library/Safari` (`PasswordBreachStore.plist`), and fetch over its own
  connection, as this Mac. They are taken out again whenever a menu gets an item or opens, and their
  three actions show our notice instead — replaced where AppKit and WebKit implement them, and
  stopped in the application's `sendAction:to:from:`, since with a page's field focused something
  else in the responder chain took them and the notice never came (run 463). After the menu, the walk
  sends the three actions to the first responder, as a key or a context menu would: our notice, for
  each of the three, on both (run 468).
- **File › New Window (⌘N)** was disabled on both: Safari's action opens a window for Safari's own
  profiles, which a profile's process does not have. It opens a window of the profile.
- **A crash of the profile's process in Safari's tab groups** (run 461, macOS 26): a page loaded in a
  window with a tab group had Safari's tab group manager ask its iCloud sync agent to sync, through
  the connection a profile's process is refused, and the process ended in `objc_storeWeak`
  (`_objc_fatal`) under `-[NSXPCConnection _sendInvocation:…]`. The sync scheduling does nothing in a
  profile (`SafariChrome.stubChromeFeatures`); a profile's tab groups stay in its home.
- **Safari's settings for its own services were written into the account's
  `~/Library/Preferences/com.apple.Safari.plist`** at every profile's launch (run 457, both macOS),
  and no preferences file was in the profile's home: `CFFIXED_USER_HOME` does not move a preferences
  domain. They now live in the process's argument domain only (docs/ISOLATION_AND_LIMITATIONS.md,
  "Preferences"; checked by the self-test); in run 468 the file was absent before the walk and after
  it, on both.
- **The profile's process did little but ask for a view it is refused**, from a few seconds after
  its start (every walk read, both macOS: "…endpoint for listener 'com.apple.view-bridge':
  Connection invalid" about a million times a walk). SafariPlatformSupport's completion list is the
  view of a service of Safari's, which the kernel refuses a profile's process; each time that
  view's service ended, `-[SPSafariPlatformSupport viewServiceDidTerminateWithError:]` asked for it
  again, on the main thread (a sample, measurement run 473). It does nothing in a profile, replaced
  once SafariPlatformSupport is loaded — replacing it with the others did nothing, since that
  framework loads later (run 475): twenty times a walk since (run 476), and the walk fails above a
  thousand.
- **Items whose work is done outside the profile** (the owner's decisions on this walk): File › Add
  to Dock… made a web app that runs in Safari's own web-app container, outside the profile and its
  proxy (docs/SAFARI_PROCESS.md); File › Import Browsing Data from File or Folder… and Export
  Browsing Data to File… put passwords and cards into this Mac's keychain and take them from there;
  View › Show Shared with You showed what was shared with this Mac's Messages account. They are out
  of a profile's menu, kept out as Safari fills its menus, and their actions show our notice however
  they are sent — Safari's Share menu has an Add to Dock… of its own (not walked: the walk takes the
  menu bar). The walk sends the four actions to the first responder after the menu, as with
  AutoFill's. With Show Shared with You gone, its view is no longer over the page when the walk
  reaches View › Show Reader and Show Tab Overview, which were disabled behind it: both are enabled
  and chosen, Tab Overview takes the window's first responder, and the View items after them —
  Reload, Zoom, Text Encoding — are disabled (runs 494 and 496, three walks on each macOS, the
  same every time; the records follow). That the overview, which the walk leaves as it is, is
  still up for them is the likely reason; it is not measured. The import and export of the
  profile's own bookmarks stay (the owner's answer to question 4): Import From › Bookmarks HTML File…
  and Export › Bookmarks…, which some runs have in place of the two Browsing Data items, on either
  Safari (run 463 on Safari 27, run 468's second attempt on both); where Safari's File menu has the
  Browsing Data items instead, Safari's own two actions (`importBookmarks:`, `exportBookmarks:`) are
  put back after Export as PDF…, under the same titles. The self-test checks that the File menu has
  both, whichever Safari built.
- **History › Home (⇧⌘H)** went to Safari's default home page, apple.com/startpage. It goes to the
  profile's start page (the owner's decision): Safari's own home page setting, in the process's
  argument domain, which Safari's action reads; a profile without a start page has Safari's default.
  Checked by the self-test.

- **What Safari's chrome saves as its preferences** — its window's frame, toolbar, sidebar, favorites
  bar, start page sections, some WebKit preferences — went to this app's own preferences domain in
  the account's real home, shared by every profile and outside the vault (runs 456 and 468: 52 to 58
  keys added during a walk). It is each profile's own, in its home and its vault (81e8c24, the
  owner's decision; docs/ISOLATION_AND_LIMITATIONS.md), but for one key of the toolbar AppKit still
  writes there on macOS 26; the walk lists what this app's domain got (run 520: nothing on 27, that
  key on 26).

**Found, open:**

- **Bookmarks › Add Bookmark… (⌘D) and Add Bookmarks for Open Tabs… do not work** (**broken** in the
  table). Each throws — a bookmark folder with no title in the sheet's location menu
  (`-[NSMenu(WebBookmarkNSMenuExtras) safari_addMenuItemForBookmarkFolder:]` from
  `-[BookmarkEditSheetController _populateLocationPopUp]`) — and our notice comes instead of the
  sheet: no bookmark is added that way. So in every walk since run 468: CI's on both macOS (run 520)
  and the owner's (1 November). Each walk makes an empty tab group before these items; in a profile
  without tab groups it is not measured. Not fixed in the owner's week: no change to the product.
- **Safari's browsing assistant worker** (`com.apple.parsec.SafariBrowsingAssistantWorker`, outside
  the profile) started in three of the eight walks on macOS 26 read — runs 457, 461 and 468, each
  time during another item (Hide Safari, View › Zoom Out, History › Show All History) — and in none
  on macOS 27; each time among a batch of the system's machine-learning workers that ran in the same
  minutes (mlhost's, Lighthouse's, differential privacy's telemetry), the system making all their
  containers in the account's home then; in the other five walks neither it nor they ran. Most
  likely the system's own schedule, not the profile's. Not measured: what starts it (the hooks on
  `NSXPCConnection` refuse names with "parsec", the kernel's rule names `com.apple.Safari` services
  only, and a request through libxpc or through another of the system's services would pass both),
  nor what it sends.
- **Edit › Paste on the login page, macOS 26** (runs 460 and 463): the real
  `~/Library/Safari/PasswordBreachStore.plist` and Safari's password breach agent's preferences were
  written meanwhile — not by the profile's processes (the walk's `fs_usage` trace of the app's,
  WebKit's and cfprefsd's calls has none), by Safari's password breach agent most likely. Run 468,
  which lists Safari's agents per item, saw no such write and no agent of Safari's start then, in
  either of its two attempts.
- **Written in the real Safari's places or the keychain by a process the walk cannot name** (FSEvents
  says what, not who; `fs_usage` saw none of the profile's processes write there): Safari's cache
  deletion extension's container (`com.apple.Safari.CacheDeleteExtension`; the extension started
  meanwhile, most likely run by the system's cache deletion) and the account's login keychain
  (`login.keychain-db`, which securityd writes for whichever process asks), once each, on macOS 26,
  in run 468's first attempt; not in its second.
- **An exception thrown by Safari's code inside one of this app's Swift tasks** leaves the Swift
  runtime's record of the running job pointing into a stack that is gone; the next check of the main
  actor then ends the process (run 460: the walk's own task, fixed in the walk by choosing items from
  the run loop as a click does). A click has no Swift task under it; code of ours that calls into
  Safari's from a task does. A small Objective-C target (`ObjCExceptions`, the owner's decision)
  catches them where they are thrown, with a `@try` around the call (`PBCatchException`): around
  Safari's window factory and its tab's first load, which a profile's launch calls from its task —
  an exception there opens our own window instead of ending the process. The self-test throws one
  from a task and sees it caught and the task going on. Other calls into Safari's code from tasks
  are not looked for one by one.
- AppKit throws and catches its own "layout constraints are not satisfiable" in View › Enter Full
  Screen and in Edit › Distraction Control › Report Issues… (both macOS): logged, nothing else.

Disabled on both, by design or because Safari's services are not there: Safari Extensions… (Safari's
extensions are the real Safari's), Edit › AutoFill Form (AutoFill from this Mac is off), Clear
History… and Clear History and Keep Website Data… (Safari's history is not built in a profile: H1).

## Item by item

Every item of the menu bar, in menu order, with what it did on each Safari in CI run 520 (the commit
fea9a3f, Safari 26.6.2 and 27.0.1) and what is decided about it:

- **keep**: it works in the profile, or does nothing harmful;
- **ours**: answered by this app instead of Safari's code;
- **fixed**: it did harm or did not work, and now does what is meant — the walk is the proof;
- **removed**: taken out of a profile's menu (the owner's decisions);
- **broken**: it should work and does not. Open: the row says what happens instead, and "Found,
  open" above says what is known.

What an item did is the walk's words: *disabled*; *changes the window* (the key window, its first
responder, its page or zoom, a window or sheet closed); a window, sheet or panel by class; *alert*,
*open panel*, *save panel* (answered with their cancel button); *our notice*, *our Settings*;
*another app in front*; *hides other apps*, *quit*, *Help*, *character viewer* (asked for, not done);
an exception by name; *nothing seen*; *—* where that Safari has no such item. Whether a window
changed or nothing was seen follows timing, and whether Start Dictation… is enabled the system: those
differ from walk to walk (the record leaves them out).

| Item | Keys | Safari 26 | Safari 27 | Decision |
|---|---|---|---|---|
| Safari › About Safari | - | changes the window; window NSPanel | changes the window; window NSPanel | **keep**: the standard About panel |
| Safari › Safari Extensions… | - | disabled | disabled | **keep**: disabled: Safari's extensions are the real Safari's, off in a profile |
| Safari › Settings… | ⌘, | our Settings | our Settings | **ours**: the manager's Settings (Safari's own have no place in a profile) |
| Safari › Settings for This Website… | - | changes the window; window _NSPopoverWindow | changes the window; window _NSPopoverWindow | **keep**: per-site settings, kept in the profile's home |
| Safari › Connection Security Details… | - | disabled | disabled | **keep**: the page's certificate |
| Safari › Clear History… | - | disabled | disabled | **broken**: disabled: Safari's history is not built in a profile (open: H1) |
| Safari › Clear History and Keep Website Data… | - | disabled | disabled | **broken**: disabled: Safari's history is not built in a profile (open: H1) |
| Safari › Services | - | not chosen: services | not chosen: services | **keep**: not chosen: the system's Services hand the selection to other applications |
| Safari › Hide Safari | ⌘H | another app in front; changes the window | another app in front; changes the window | **keep** |
| Safari › Hide Others | ⌥⌘H | hides other apps | hides other apps | **keep** |
| Safari › Show All | - | disabled | disabled | **keep** |
| Safari › Quit Safari | ⌘Q | quit | quit | **keep**: quits the profile's process: the profile closes and is sealed, the app stays |
| File › New Window | ⌘N | changes the window; window BrowserWindow | changes the window; window BrowserWindow | **fixed**: a new window of the profile (Safari's own action stayed disabled) |
| File › New Tab | ⌘T | changes the window | changes the window | **keep** |
| File › New Tab at End | ⌥⌘T | changes the window | changes the window | **keep** |
| File › New Empty Tab Group | ⌃⌘N | changes the window | changes the window | **keep** |
| File › New Tab Group with This Tab | - | disabled | disabled | **keep** |
| File › Open File… | ⌘O | open panel | open panel | **keep** |
| File › Open Location… | ⌘L | changes the window | changes the window | **keep** |
| File › Close Window | ⇧⌘W | alert | alert | **keep** |
| File › Close Window | ⇧⌘W | nothing seen | nothing seen | **keep** |
| File › Close All Windows | ⌥⇧⌘W | alert; changes the window | alert; changes the window | **keep** |
| File › Close All Windows | ⌥⇧⌘W | nothing seen | nothing seen | **keep** |
| File › Close Tab | ⌘W | changes the window | changes the window | **keep** |
| File › Close Other Tabs | - | disabled | disabled | **keep**: its keys follow the Mac: ⌥⌘W on the owner's and in one CI walk of four, none in the others |
| File › Delete Tab Group | ⌃⌘W | alert | alert | **keep** |
| File › Save As… | ⌘S | nothing seen | nothing seen | **keep** |
| File › Save As… | ⇧⌘S | nothing seen | nothing seen | **keep** |
| File › Share… | - | window _NSPopoverWindow | changes the window; window _NSPopoverWindow | **keep**: the system's share picker (a popover): what is shared goes where the user sends it, with this Mac's accounts |
| File › Export as PDF… | - | nothing seen | nothing seen | **keep** |
| File › Import From › Bookmarks HTML File… | - | open panel | open panel | **keep**: the profile's bookmarks, from a file the user picks; put back where Safari's File menu has the Browsing Data items instead |
| File › Export › Bookmarks… | - | save panel | save panel | **keep**: the profile's bookmarks, to a file the user picks (E2: on the owner's Mac no file was written, in CI it is — open); put back where Safari's File menu has the Browsing Data items instead |
| File › Print… | ⌘P | changes the window; sheet NSPanel | changes the window; sheet NSPanel | **keep**: the print panel (answered Cancel); in some walks the system's notification center came forward |
| Edit › Undo | ⌘Z | nothing seen | nothing seen | **keep** |
| Edit › Redo | ⇧⌘Z | nothing seen | nothing seen | **keep** |
| Edit › Cut | ⌘X | nothing seen | nothing seen | **keep** |
| Edit › Copy | ⌘C | nothing seen | nothing seen | **keep** |
| Edit › Copy Search Terms | ⌃⌘C | disabled | disabled | **keep** |
| Edit › Paste | ⌘V | nothing seen | nothing seen | **keep**: on macOS 26 the real ~/Library/Safari/PasswordBreachStore.plist was written meanwhile in runs 460 and 463, not since — not by the profile's processes (fs_usage); by Safari's password breach agent, most likely |
| Edit › Paste and Match Style | ⌥⇧⌘V | nothing seen | nothing seen | **keep** |
| Edit › Paste as Typed | ⌃⌘V | alert | alert | **ours**: our paste as typed (keys typed into the page's field) |
| Edit › Delete | - | nothing seen | nothing seen | **keep** |
| Edit › Select All | ⌘A | nothing seen | nothing seen | **keep** |
| Edit › AutoFill Form | ⇧⌘A | disabled | disabled | **keep**: disabled: AutoFill from this Mac is off in a profile |
| Edit › Save Webpage With Metadata | ⌃⌘S | disabled | disabled | **keep** |
| Edit › Distraction Control › Hide Distracting Items... | - | alert | alert | **keep** |
| Edit › Distraction Control › Show Hidden Items | - | disabled | disabled | **keep** |
| Edit › Distraction Control › Report Issues... | - | alert; exception NSGenericException | alert; exception NSGenericException | **keep**: Safari's report form, answered Cancel; AppKit's layout exception, when it comes, is caught inside AppKit |
| Edit › Find › Google Search… | ⌥⌘F | changes the window | changes the window | **keep** |
| Edit › Find › Find… | ⌘F | changes the window | changes the window | **keep** |
| Edit › Find › Find Next | ⌘G | disabled | disabled | **keep** |
| Edit › Find › Find Previous | ⇧⌘G | disabled | disabled | **keep** |
| Edit › Find › Hide Find Banner | ⇧⌘F | changes the window | changes the window | **keep** |
| Edit › Find › Use Selection for Find | ⌘E | nothing seen | nothing seen | **keep** |
| Edit › Find › Jump to Selection | ⌘J | disabled | disabled | **keep** |
| Edit › Spelling and Grammar › Show Spelling and Grammar | ⌘: | disabled | disabled | **keep** |
| Edit › Spelling and Grammar › Check Document Now | ⌘; | disabled | disabled | **keep** |
| Edit › Spelling and Grammar › Check Spelling While Typing | - | nothing seen | nothing seen | **keep** |
| Edit › Spelling and Grammar › Check Grammar With Spelling | - | nothing seen | nothing seen | **keep** |
| Edit › Spelling and Grammar › Correct Spelling Automatically | - | disabled | disabled | **keep** |
| Edit › Substitutions › Show Substitutions | - | disabled | disabled | **keep** |
| Edit › Substitutions › Smart Copy/Paste | - | disabled | disabled | **keep** |
| Edit › Substitutions › Smart Quotes | - | disabled | disabled | **keep** |
| Edit › Substitutions › Smart Dashes | - | disabled | disabled | **keep** |
| Edit › Substitutions › Smart Links | - | disabled | disabled | **keep** |
| Edit › Substitutions › Text Replacement | - | disabled | disabled | **keep** |
| Edit › Transformations › Make Upper Case | - | disabled | disabled | **keep** |
| Edit › Transformations › Make Lower Case | - | disabled | disabled | **keep** |
| Edit › Transformations › Capitalize | - | disabled | disabled | **keep** |
| Edit › Speech › Start Speaking | - | nothing seen | nothing seen | **keep** |
| Edit › Speech › Stop Speaking | - | nothing seen | nothing seen | **keep** |
| Edit › Start Dictation… | D | nothing seen | nothing seen | **keep**: the system's dictation; whether it is enabled follows the system, and its second key the Mac (a MacBook's dictation key on the owner's) |
| Edit › Start Dictation… | D | disabled | disabled | **keep**: the system's dictation; whether it is enabled follows the system, and its second key the Mac (a MacBook's dictation key on the owner's) |
| Edit › Emoji & Symbols | ⌘ | character viewer | character viewer | **keep** |
| Edit › Emoji & Symbols | ⌃⌘ | character viewer | character viewer | **keep** |
| Edit › Emoji & Symbols | E | character viewer | character viewer | **keep** |
| View › Always Show Toolbar in Full Screen | - | disabled | disabled | **keep** |
| View › Customize Toolbar… | - | changes the window; sheet NSToolbarConfigPanel | changes the window; sheet NSToolbarConfigPanel | **keep** |
| View › Always Show Tab Bar | - | nothing seen | nothing seen | **keep** |
| View › Show Favorites Bar | ⇧⌘B | nothing seen | nothing seen | **keep** |
| View › Show Status Bar | ⌘/ | disabled | disabled | **keep** |
| View › Show Sidebar | ⇧⌘L | nothing seen | nothing seen | **keep** |
| View › Show Bookmarks Sidebar | ⌃⌘1 | nothing seen | nothing seen | **keep** |
| View › Show Reading List Sidebar | ⌃⌘2 | nothing seen | nothing seen | **keep** |
| View › Show Reader | ⇧⌘R | nothing seen | nothing seen | **keep** |
| View › Show Tab Overview | ⇧⌘\ | changes the window | changes the window | **keep** |
| View › Show Downloads | ⌥⌘L | disabled | disabled | **keep** |
| View › Stop | ⌘. | disabled | disabled | **keep** |
| View › Reload Page | ⌘R | disabled | disabled | **keep** |
| View › Reload Page From Origin | ⌥⌘R | disabled | disabled | **keep** |
| View › Reload With Content Blockers | - | disabled | disabled | **keep** |
| View › Actual Size | ⌘0 | disabled | disabled | **keep** |
| View › Zoom In | ⌘+ | disabled | disabled | **keep** |
| View › Make Text Bigger | ⌥⌘+ | disabled | disabled | **keep** |
| View › Zoom Out | ⌘- | disabled | disabled | **keep** |
| View › Make Text Smaller | ⌥⌘- | disabled | disabled | **keep** |
| View › Text Encoding › Default | - | disabled | disabled | **keep** |
| View › Enter Full Screen | F | changes the window; window NSToolbarFullScreenWindow | changes the window; window NSToolbarFullScreenWindow | **keep**: AppKit's layout exception, when it comes (runs 463 and 468), is caught inside AppKit |
| View › Enter Full Screen | ⌃⌘F | changes the window; window NSToolbarFullScreenWindow | changes the window; window NSToolbarFullScreenWindow | **keep**: AppKit's layout exception, when it comes (runs 463 and 468), is caught inside AppKit |
| History › Show All History | ⌘Y | changes the window | changes the window | **keep** |
| History › Back | ⌘[ | changes the window | changes the window | **keep** |
| History › Forward | ⌘] | disabled | disabled | **keep** |
| History › Home | ⇧⌘H | nothing seen | nothing seen | **fixed**: (the owner's decision) the profile's start page, Safari's own home page setting in the process's argument domain; Safari's default (apple.com/startpage) for a profile without one |
| History › Return to Search Results | ⌥⌘S | disabled | disabled | **keep** |
| History › Reopen Last Closed Window or Tab | ⇧⌘T | nothing seen | nothing seen | **keep** |
| History › Reopen All Windows from Last Session | - | disabled | disabled | **keep** |
| Bookmarks › Show Start Page | - | changes the window | changes the window | **keep** |
| Bookmarks › Show Bookmarks | - | nothing seen | changes the window | **keep** |
| Bookmarks › Edit Bookmarks | ⌥⌘B | changes the window | changes the window | **keep** |
| Bookmarks › Add Bookmark… | ⌘D | exception NSInternalInconsistencyException; our notice | exception NSInternalInconsistencyException; our notice | **broken**: does not work: throws (a bookmark folder with no title in the sheet's location menu); our notice comes instead of the sheet, and no bookmark is added — in every walk, CI's and the owner's, each of which has made an empty tab group before it; without tab groups, not measured |
| Bookmarks › Add Bookmarks for Open Tabs… | - | exception NSInternalInconsistencyException; our notice | exception NSInternalInconsistencyException; our notice | **broken**: does not work: the same as Add Bookmark… |
| Bookmarks › Add Bookmark Folder | - | changes the window | changes the window | **keep** |
| Bookmarks › Add to Reading List | ⇧⌘D | nothing seen | nothing seen | **keep** |
| Bookmarks › Add Open Tabs to Reading List | - | nothing seen | nothing seen | **keep** |
| Bookmarks › Select Previous Item in Reading List | - | disabled | disabled | **keep** |
| Bookmarks › Select Next Item in Reading List | - | disabled | disabled | **keep** |
| Window › Minimize | ⌘M | changes the window | changes the window | **keep** |
| Window › Minimize All | ⌥⌘M | changes the window | changes the window | **keep** |
| Window › Zoom | - | nothing seen | nothing seen | **keep** |
| Window › Arrange Tabs By › Title | - | nothing seen | nothing seen | **keep** |
| Window › Arrange Tabs By › Website | - | nothing seen | nothing seen | **keep** |
| Window › Show Previous Tab | ⌃⇧⇥ | changes the window | changes the window | **keep** |
| Window › Show Next Tab | ⌃⇥ | nothing seen | nothing seen | **keep** |
| Window › Go To Previous Tab Group | ⇧⌘ | disabled | disabled | **keep** |
| Window › Go To Previous Tab Group | ⌃⌘[ | disabled | disabled | **keep** |
| Window › Go To Previous Tab Group | ⌥⌘[ | disabled | disabled | **keep** |
| Window › Go To Next Tab Group | ⇧⌘ | disabled | disabled | **keep** |
| Window › Go To Next Tab Group | ⌃⌘] | disabled | disabled | **keep** |
| Window › Go To Next Tab Group | ⌥⌘] | disabled | disabled | **keep** |
| Window › Pin Tab | - | nothing seen | nothing seen | **keep** |
| Window › Duplicate Tab | - | nothing seen | nothing seen | **keep** |
| Window › Move Tab to New Window | - | changes the window; window BrowserWindow | changes the window; window BrowserWindow | **keep** |
| Window › Merge All Windows | - | disabled | disabled | **keep** |
| Window › (untitled) | ⌃⌘L | disabled | disabled | **keep** |
| Window › Mute This Tab | - | nothing seen | nothing seen | **keep** |
| Window › Mute Other Tabs | - | disabled | disabled | **keep** |
| Window › Bring All to Front | - | nothing seen | nothing seen | **keep** |
| Window › (a window of the profile) | - | nothing seen | nothing seen | **keep** |
| Help › Safari Help | ⌘? | Help | Help | **keep**: Safari's help, in the Help viewer (another application) |
| Help › Acknowledgments | - | changes the window | changes the window | **keep** |
| (sent to the first responder) _handleInsertFromContactsCommand: | - | our notice | changes the window; our notice | **fixed**: our notice: AutoFill from this Mac is off in profiles |
| (sent to the first responder) _handleInsertFromPasswordsCommand: | - | our notice | our notice | **fixed**: our notice: AutoFill from this Mac is off in profiles |
| (sent to the first responder) _handleInsertFromCreditCardsCommand: | - | our notice | our notice | **fixed**: our notice: AutoFill from this Mac is off in profiles |
| (sent to the first responder) generateWebAppForCurrentPage: | - | our notice | our notice | **removed**: (the owner's decision), not in a profile's menu: a web app made from the page runs in Safari's own web-app container, outside the profile and its proxy — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| (sent to the first responder) _importFromFile: | - | our notice | our notice | **removed**: (the owner's decision), not in a profile's menu: it imported passwords and cards into this Mac's keychain, not into the profile — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| (sent to the first responder) runExportDataPanel: | - | our notice | our notice | **removed**: (the owner's decision), not in a profile's menu: its passwords and cards were this Mac's keychain's, not the profile's — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| (sent to the first responder) toggleSharedWithYou: | - | our notice | our notice | **removed**: (the owner's decision), not in a profile's menu: it showed what was shared with this Mac's Messages account — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |

Taken out of a profile's menu (not walked as items: their actions are sent to the first responder, above):

| Item | Decision |
|---|---|
| File › Add to Dock… | **removed** (the owner's decision), not in a profile's menu: a web app made from the page runs in Safari's own web-app container, outside the profile and its proxy — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| File › Import Browsing Data from File or Folder… | **removed** (the owner's decision), not in a profile's menu: it imported passwords and cards into this Mac's keychain, not into the profile — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| File › Export Browsing Data to File… | **removed** (the owner's decision), not in a profile's menu: its passwords and cards were this Mac's keychain's, not the profile's — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
| View › Show Shared with You | **removed** (the owner's decision), not in a profile's menu: it showed what was shared with this Mac's Messages account — sent to the first responder, as a key or Safari's Share menu would send it, its action shows our notice |
