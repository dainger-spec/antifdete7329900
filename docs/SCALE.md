# Many profiles: what the app holds, measured

Before the product is sold it has to be known how many profiles it holds: how long they take to
make, what they take on disk, whether the Profiles window still works with hundreds of them, how
many can run at once before the Mac gives out, and whether quitting with many running loses
anything. Nobody had measured it; the owner has 22 profiles and had never run more than ten at once.

## How it is measured

`scripts/scale_check.py` runs `PrivacyBrowser --scale-check` (`ScaleCheck.swift`) with the
self-test proxy started for it, on GitHub's macOS runners (`.github/workflows/scale.yml`: when its
own files change, every Monday, and by hand). Everything runs as the app runs it:

1. **Making profiles** — 200, one by one, through `ProfileRepository.create`, two thirds with an
   HTTP proxy, each with tags and notes; each creation timed, and the vault measured on disk
   before and after.
2. **The Profiles window** — what it does on every refresh, timed five times over all of them:
   the index read and every profile's settings decrypted (`AppModel.refresh`), the rows built.
   Then its search (by name, tag and notes) and its filters (all, with a proxy, ephemeral, a tag)
   run over all the rows, timed, and checked against the counts they must give; and the window
   itself drawn with 20 rows and with all of them (`profiles-20.png`, `profiles-200.png` in the
   run's artifact).
3. **Running at once** — groups of 1, 5, 10, 20 and 30 profiles launched as the list's Launch does
   for a selection (all at once, each in a process of its own with Safari's window, its start page
   loading through the self-test proxy). For each group: the time until each window is up (waited
   for up to a minute, plus fifteen seconds a profile); ten seconds later, the memory footprint of
   the profiles' own processes and of every process that started for them (WebKit's web content
   and networking processes, and the system's services inside `.xpc` bundles: found by when they
   started, since the system holds WebKit's processes responsible to the app's first process, not
   to the profile), the kernel's memory pressure, the machine's free and compressed memory and
   swap, how busy its processors were from the launch on; a profile whose window did not come up,
   and why (its process gone and how, or alive and where: the first two such processes are
   sampled, `stuck-<pid>.txt`); then the time to stop and seal them all, and what still ran three
   seconds later. The app's crash reports written meanwhile are in the report.
4. **Quitting with ten running** — ten profiles up, each with a cookie its start page set, then
   the app's own quit (every profile stopped and sealed at once): how long until all were sealed,
   how each seal went. Then each is started again on a page that sets nothing, and its cookie is
   looked for.
5. **One more launch** with every profile in the vault, and the vault's size once they have run.

The start page is nearly empty: what is measured is what a profile costs by itself. A real site
adds what it adds in Safari — its web content process alone is often several hundred megabytes.
The machine is a GitHub runner (3 processors, 7 GB), not a customer's Mac: the figures per profile
carry over, the totals scale with the Mac's processors and memory.

## What it measured

Seven runs on each of GitHub's macOS 26.6.2 and 27.0.1 runners (CI runs 457, 460, 461, 468 and 470
of the measurement branch, the last two twice each; 470 with the fix below; the figures are the
range over the fourteen, or per macOS where they differ).

**Making 200 profiles** took 0.4 to 1.8 s in all — a median of 1.6 to 6.3 ms each, the last ten no
slower than the first — and the vault then took 0.83 MB, 4.2 KB a profile.

**The Profiles window with 200 profiles** works: a refresh (the index read, every profile's
settings decrypted, the rows built) took 16 to 57 ms; search by name, tag and notes 0.5 to 3.8 ms;
the filters under 0.2 ms; every count right, the tags all there. The window drew its 200 rows in
3.1 to 7.0 s and its first 20 in 2.2 to 5.3 s, each with 1.5 s of waiting for the window: about two
seconds more for the 180 rows more in most runs (from nothing to 4.4 s), on a runner — the one cost
of our own code that grows with the number of profiles. One more launch with all 200 in the vault
took 1.4 to 4.3 s, as one launch does.

**Running at once** (start: from the launch to the profile's window, of the windows that came up;
memory: the profiles' own processes and every process that started for them):

| At once | macOS | Start, median | Slowest | Memory, per profile | Processes | Processors busy | Stop them all |
|---|---|---|---|---|---|---|---|
| 1 | 26 | 3.0–6.8 s | — | 137–178 MB | 8–14 | 43–81 % | 4.6–5.8 s |
| 1 | 27 | 3.3–6.8 s | — | 142–186 MB | 13–19 | 40–90 % | 4.5–5.3 s |
| 5 | 26 | 5.1–10.1 s | 6.5–10.2 s | 126–152 MB | 38–45 | 65–92 % | 4.8–8.1 s |
| 5 | 27 | 4.4–16.2 s | 4.9–17.7 s | 132–151 MB | 52–58 | 64–98 % | 4.8–6.7 s |
| 10 | 26 | 9.0–18.7 s | 12.2–29.1 s | 135–155 MB | 76–80 | 79–100 % | 5.5–7.5 s |
| 10 | 27 | 10.0–29.9 s | 15.4–38.0 s | 145–164 MB | 101–112 | 85–100 % | 6.7–9.5 s |
| 20 | 26 | 18.0–44.7 s | 20.6–50.1 s | 112–142 MB | 109–151 | 33–98 % | 8.8–28.1 s |
| 20 | 27 | 33.4–55.0 s | 41.1–352 s | 126–168 MB | 166–222 | 88–100 % | 6.3–31.1 s |
| 30 | 26 | 36.6–69.6 s | 46.8–94.0 s | 114–154 MB | 162–230 | 62–100 % | 14.5–39.5 s |
| 30 | 27 | 39.3–131 s | 45.0–429 s | 88–170 MB | 178–330 | 93–100 % | 9.2–34.5 s |

The kernel's memory pressure stayed "normal" in every group of every run; swap stayed at 0 but
once (43 MB, macOS 27, thirty at once). Each profile runs 6 to 12 processes: its own (55–65 MB),
one or two of WebKit's web content (about 20 MB each on this page; on macOS 27 also an "enhanced
security" one), WebKit's networking (8 MB), and services of the system's that start for it — the
open and save panel's (20 to 35 MB, at launch, with no panel asked for), Quick Look's, an audio
helper, Metal's shader compiler on macOS 26, and on macOS 27 two or three more.

Where it gave out:

- **macOS 26: a profile's process crashed at its start**, in three runs of the five before the fix:
  one of thirty at once in runs 460 and 461, one of twenty in run 468's second attempt (status 11, a
  segmentation fault). The one whose crash report was kept (468): `objc_retain` under
  `-[NSXPCConnection remoteObjectProxy]`, in the block `-[WBTabGroupSyncAgentProxy
  addSyncObserver:]` runs on its sync observer queue — Safari's proxy for its iCloud tab group sync
  agent, whose connection a profile's process is refused (`ProfileNetworkGuard`: "SyncAgent"), and
  whose `scheduleSyncIfNeeded` had ended the menu walk's process the same way (docs/SAFARI_MENU.md).
  Its observers do nothing in a profile now, as its sync scheduling
  (`SafariChrome.stubChromeFeatures`): in the two runs since (470, twice) no profile's process
  crashed, and all thirty came up within 92 s.
- **macOS 27: windows came after minutes, or not at all**, in six runs of seven: with thirty at once
  4, 25, 18 and 19 of the 30 had no window by the end of the wait, and in run 470 (twice) all thirty
  came but the last after 160 s; with twenty, 8 had none by the end of the wait in one run (three
  minutes, then) and the last one came after 352 s in another; only in run 468's first attempt did
  all thirty come within 80 s. Their processes are alive, at about 48 MB, early in their start. The
  two sampled (run 468's second attempt) have their main thread in Safari's first window coming to
  the front (`-[BrowserWindowController showWindow:]`, `-[NSWindow makeKeyAndOrderFront:]`) and in
  its list of windows (`+[BrowserWindowController allBrowserTabViewItemsFromAllWindows]`), each time
  waiting for the window server's answer (SkyLight's
  `SLSWindowServerClientCopyBestManagedDisplayForRect` and its window-ordering query, in `mach_msg`)
  for the whole two seconds sampled. With twenty or thirty processes bringing their first window up
  at once, macOS 27's window server on the runner answers in minutes; macOS 26's did not stall in
  any run. In the four runs where windows had not come by the end of the wait, one to three of the
  profiles' processes logged, from several threads, "+[NSXPCSharedListener
  endpointForReply:withListenerName:replyErrorCode:]: an error occurred while attempting to obtain
  endpoint for listener 'com.apple.view-bridge': Connection invalid" 320,000 to 2,100,000 times
  each, for four to nine minutes; in the three where every window came, at most 90,000 times. A
  sample of the menu walk's profile process, which logs the same from its start (run 473), has its
  main thread in a loop: SafariPlatformSupport's completion list is the view of a service of
  Safari's, which the kernel refuses a profile's process, and each time that view's service ended,
  -[SPSafariPlatformSupport viewServiceDidTerminateWithError:] asked for the view again, and it
  ended at once. That method does nothing in a profile now (`SafariChrome.stubLateFeatures`,
  replaced once its framework is loaded): in the run since (476) no process logged it, and on macOS
  27 all thirty came up within 108 s — one run, so whether the loop was what held the window server
  is likely, not proven.
- **Stopping** grows past ten: from about 5 to 9 s for up to ten to 6–35 s for twenty or thirty.

**Quitting with ten running** took 5.1 to 13.6 s until every one was sealed; every seal was forced
(WebKit had not let go of the store after the retries a quit allows, `prepareForQuit`); and every
profile's cookie was there at its next launch, ten of ten in every run.

**On disk**, after 67 of the 200 had run once on a page or two each, the vault took 210 to 226 MB:
about 3.2 MB a profile that has run (its sealed web data and Safari's home), and a profile's data
grows from there with what it browses.

## What the product holds today, and what gives out first

Profiles kept: 200 are no load at all — making, listing, searching and filtering them is a matter of
milliseconds, and their settings take kilobytes; the Profiles window takes about two seconds more to
draw at 200 than at 20. Profiles running at once, on a Mac like the runner (3 processors, 7 GB):
**ten** start reliably, in 10 to 40 s; **twenty** start on macOS 26 within a minute, and on macOS 27
within one to six; **thirty** is past it: on macOS 26 they come within a minute and a half (and,
before the fix above, one of them crashed at its start in three runs of five), on macOS 27 the last
window takes minutes or does not come.

What gives out first is **the processor at launch**: a profile's start takes several seconds of
processor time (Safari's frameworks and window, WebKit's processes, Metal compiling shaders), the
list's Launch starts all of a selection at once, and the runner's three processors stay busy from
the first launch to the last window. On macOS 27, **the window server** comes next: twenty or
thirty first windows asked for at once were answered in minutes, while one to three processes asked
for a refused view again as fast as they could (above, fixed since). **Memory** comes after: about 150 MB a profile on a
nearly empty page, thirty in 4 to 5 GB (when all were up) without pressure on 7 GB; a real site adds
what it adds in Safari, often hundreds of megabytes a tab, so with real pages memory is what bounds
the number that can keep running. **Disk** and **our own code** are not near a limit. Starting a
selection a few at a time, each after the window before it is up, would keep the first two out of
the way (the owner's decision).
