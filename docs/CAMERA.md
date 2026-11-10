# Camera substitution

What a profile's page is handed when it asks for the camera with `getUserMedia({video})`, instead
of this Mac's real camera — and, with it, what happens to the microphone. Set per profile in the
editor's **Camera** part; off by default.

Like the rest of `PrivacyScripts`, this is a JavaScript shim over the media-capture APIs, not a
system capture device (a CoreMediaIO plug-in or a Camera Extension would be a separate, signed
system extension — out of scope here). It is honest about that: a page that correlates the frames
with a live sensor can still tell a drawn frame from a camera's.

## Where it runs

The shim is part of the profile's injected scripts (`PrivacyScripts.shimBody`), so it runs wherever
those run:

- **a window of Safari's** — the released macOS case. A profile's process hosts Safari's chrome
  (`SafariChromeHost`); `ProfileNetworkGuard` injects the profile's scripts into every web view
  Safari builds (`BrowserSession.applyContent` / `restoreContent`). The camera shim rides that exact
  path — the same one the time-zone, geolocation, WebRTC and iPhone shims ride — so it needs no
  window code of its own. There is nothing in `BrowserTab` or `BrowserWindowController` for it;
  those are the app's own fallback window only (`SafariChromeHost.reasonForOwnWindow`).
- **the app's own window** — the fallback (an iPhone/iPad view, the sandboxed build, a chrome that
  would not come up). The same injected scripts, so the same behaviour.

Only in a **secure context**. `navigator.mediaDevices` does not exist over plain http on a public
origin — in any browser — so there is nothing to substitute there. https and loopback origins have
it.

## The model — `BrowserCore/Profiles/CameraSubstitution.swift`

Per-profile, stored (encrypted) and synced with the rest of the settings; written only when it is
not `.off`, so a profile that never used it is stored as before (`ProfileConfiguration`).

- **mode** — `off` (the real camera, through WebKit), `block` (no camera: `getUserMedia({video})`
  rejects `NotFoundError`, `enumerateDevices` lists no `videoinput`), or `substitute`.
- **source** — `color` (a solid colour), `bars` (a moving test pattern), `image` (a chosen photo),
  `video` (a chosen clip, looped).
- **width / height / frameRate** — what the track reports and the stream is drawn at.
- **facing**, **fit** (cover / contain / stretch), **mirror**, **deviceLabel**, **colorHex**.
- **audio** — the real microphone, a silent track, or none, when a page asks for audio.
- **alsoScreenShare** — substitute `getDisplayMedia` with the same stream, too.
- **deviceSecret** — a random secret kept with the profile; the shim derives a stable, per-origin
  `deviceId`/`groupId` from it (a real browser salts them per origin). The editor fills it when
  substitution is first turned on.
- **imageData / videoData** — the chosen media's bytes. The app reads the file (the editor's file
  picker) and keeps the bytes; the profile's pages never touch the disk, and no file path is stored
  or logged. Capped (an image at 4 MB, a video at 12 MB) because they travel with the profile.

## The shim — `PrivacyScripts.patchCamera`

Built into the one injected script, configured by `ShimConfiguration.Camera` (the chosen media
already turned into a `data:` URL by the app, so the shim never reads a file). Believability is the
same bar as the rest of the file:

- a real `canvas.captureStream()` video track — so `getSettings`, `getCapabilities`,
  `applyConstraints`, `stop`, `onended` are the engine's own;
- the replaced methods (`getUserMedia`, `enumerateDevices`, the track's `getSettings` and the rest)
  print as native code (one registry per page), carry the right `name`/`length`, and keep the
  engine's receiver checks; a real track or a real `MediaDeviceInfo` falls through untouched;
- `enumerateDevices` lists our one camera with the label only after the page is granted it (as a
  real browser hides labels until then), its `deviceId`/`groupId` salted per origin;
- faint, moving sensor-like grain on every frame, so the picture is never frozen (the first thing a
  virtual-camera check looks for), and `bars` also carries a moving bar and a running clock.

## Limitations

- The frames are drawn, not from a sensor. A check that watches for focus hunting, exposure
  changes or a real face/room can still tell.
- Secure context only (above).
- A worker never calls `getUserMedia`, so there is nothing to do in one (`substitutesInWorkers` is
  unaffected).
- The embedded image/video is capped and syncs with the profile.

## The check — `--camera-safari-check`

The ordinary self-test (`--self-test`) runs in the app's own windows, which are **not** Safari, so
it does not cover the released case. `CameraSafariCheck` (`Lumen --camera-safari-check`,
`scripts/camera_safari_check.sh`) does: a profile set to substitute its camera is started without a
window, as the editor's Run starts one; a scenario on a secure loopback page the self-test proxy
serves, in a window of Safari's, calls `getUserMedia({video})` and `enumerateDevices` in the page's
own world; it passes when the page is a secure context, the track reports the substitution's size
and label with a 64-hex per-origin `deviceId`, `getUserMedia` prints as native code, two frames a
moment apart differ, and exactly our one camera is listed. Wired into `.github/workflows/full.yml`
on macOS 26 (it gates the build) and macOS 27 (reported, `continue-on-error`), beside the scenario
check it mirrors.
