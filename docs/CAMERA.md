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
- **crop** — a normalised rectangle of the source taken into the frame, before `fit`.
- **filters** — a camera look over the source (brightness, contrast, saturation, blur, hue,
  sepia, invert, opacity, black-and-white), applied as one canvas-filter pass.
- **playback** — for the `.video` source: loop, freeze the picture, speed, and trim (start/end).
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
  `applyConstraints`, `stop`, `onended` are the engine's own, the look drawn before the grain so
  the frame the page reads carries it;
- a believable built-in camera: the default label is "FaceTime HD Camera", `getCapabilities`
  reports a fixed built-in's ranges that the reported `getSettings` fall inside (what a real
  browser's do), `facingMode` `user`;
- the replaced methods (`getUserMedia`, `enumerateDevices`, the track's `getSettings` and the rest)
  print as native code (one registry per page), carry the right `name`/`length`, and keep the
  engine's receiver checks; a real track or a real `MediaDeviceInfo` falls through untouched;
- `enumerateDevices` lists our one camera with the label only after the page is granted it (as a
  real browser hides labels until then), its `deviceId`/`groupId` salted per origin;
- faint, moving sensor-like grain on every frame, so the picture is never frozen (the first thing a
  virtual-camera check looks for), and `bars` also carries a moving bar and a running clock.

## The system camera (a CMIO Camera Extension)

For a feed that is indistinguishable at the JavaScript layer — recognised as a genuine built-in
camera, past liveness and anti-bot checks — the frames must come from the OS capture pipeline, not
a canvas. That is a **CMIO Camera Extension**: a signed system extension, bundled in the app,
activated through `SystemExtensions`, that registers a virtual capture device the whole Mac sees.
WebKit then builds the frames its own way, so a page cannot tell it from the built-in camera.

Two things that shape it:

- It is **global, not per-profile**: the virtual device is visible to every app and to this Mac's
  real Safari, and to every profile, as one device. So the per-profile layer here is still needed —
  to hide the device from `enumerateDevices` for profiles that are not using it (and from the
  "Compare with Safari" measurement), and to name it believably — otherwise the device itself is a
  cross-profile fingerprint. The system extension is the frame engine; this layer is the gate.
- It needs the app's Apple Developer signing (the `com.apple.developer.system-extension.install`
  entitlement, a provisioning profile, notarization). It builds and activates only on a Mac, so CI
  compiles it against the SDK (`CAM=check`) but cannot activate it.

### Stage 1 (here): the extension

`Sources/CameraExtension/` is the extension — a standalone SwiftPM executable target, no
BrowserCore dependency so it stays small:

- `CameraProviderSource` publishes one virtual device; `CameraDeviceSource` owns its output stream
  and generates frames; `CameraStreamSource` hands start/stop to the device.
- `CameraFrameRenderer` draws the frame (a solid colour or a moving test pattern, with grain so it
  is never frozen) into a BGRA pixel buffer, at the configured size and rate.
- `CameraExtensionConfig` reads a small JSON the app writes to the shared app group
  (`<group>/camera.json`: label, source, colour, size, frame rate), so the device can read as
  "FaceTime HD Camera" and show the chosen feed. Absent → a default test pattern.

Packaged like the network guard: `Resources/CameraExtension/Info.plist` (a `CMIOExtension` dict
with a Mach service under the app group) and `CameraExtension.entitlements` (sandboxed, the app
group, team identifiers — no network). `scripts/build-app.sh` builds and lays it out beside the app
unsigned with `CAM=check` (CI compiles it; off by default so an ordinary build is untouched), and
signs and embeds it under `Contents/Library/SystemExtensions/` with `CAM=1` (needs `CAMERA_PROFILE`
and the app's signing), mirroring the `NE=1`/`NE=check` network-guard flow.

### Stage 2 (here): the app wiring and the per-profile gate

- `SystemCamera` (mirroring `NetworkGuard`) installs and switches the extension on through
  `OSSystemExtensionManager`, records in the shared app group whether it is active, and writes the
  active profile's render settings to `<group>/camera.json`. The extension publishes itself under a
  fixed sentinel name (`CameraSubstitution.systemDeviceName`, "Lumen Camera") and re-reads the
  config each time a client starts the stream.
- **Only the app's own process can reach the app group.** A profile's own process (`LumenProfile`,
  the one that hosts Safari's window) is signed without the app-group entitlement on purpose
  (`release.sh` refuses one that has it), so there `containerURL(forSecurityApplicationGroup…)` is
  nil: the config would not be written and "active" would always read false — the device kept
  drawing the fallback test pattern and a page auto-picked the real camera (0.1.7, the owner's Mac,
  11 November). So `ProfileManager.startInOwnProcess`, in the app's own process, writes the config
  and reads whether the extension is on, and passes that to the child as `PB_SYSTEM_CAMERA_ACTIVE`
  (`ProfileProcess.systemCameraActiveForThisProcess`), as the plan's camera right is carried
  (`PB_CAMERA_ALLOWED`). "Active" means the device exists on this Mac at all — never whether this
  profile uses it: every profile must hide it otherwise. A profile run in the app's own process
  (the sandboxed build) reads and writes it directly.
- A per-profile **delivery** choice (`CameraSubstitution.delivery`): the JavaScript shim, or the
  system camera. In the editor's Camera part, with the extension's install state and an Install
  button.
- The per-profile gate (`PrivacyScripts.patchSystemCamera`): the profile that uses the system
  camera reads the sentinel device under the believable name (`deviceLabel`) with the real cameras
  hidden, so one camera shows; every other profile hides the sentinel, so the Mac-global device
  does not leak across profiles or into the Safari comparison. A plain `getUserMedia({video})` in
  the using profile is routed to the sentinel device, and the track it returns names it with the
  believable name too (`MediaStreamTrack.label`, what most camera pages show). A profile that draws
  its own camera (the JavaScript shim) already hides every real `videoinput`, so the two shims never
  both patch `enumerateDevices`.

WebKit returns empty device labels (and ids) until a page holds the camera permission — one
unnamed placeholder per kind, whatever is attached — so the sentinel can be found only after a
grant. The gate handles both sides of it:

- Before the grant, `enumerateDevices` keeps the unnamed placeholder, as Safari shows it (dropping
  it would read "no camera", and a page may then never ask). Nothing leaks: the placeholder is the
  same however many cameras there are.
- The using profile's first `getUserMedia` on a site is let through with the page's own
  constraints, so the engine asks for the permission. If what it opened is not the sentinel, that
  stream is stopped before the page ever holds it and the sentinel is opened instead; the page gets
  only the virtual camera. The cost: the Mac's real camera opens for a moment, so its light may
  blink once — at a site's first grant only. With the permission held, calls go straight to the
  sentinel. (Until 0.1.8 this first call reached the engine as `getUserMedia()` with nothing in it,
  a TypeError — `arguments` read inside the async helper — and the placeholder was dropped.)

`scripts/test-shims.mjs` covers all of it against a model of WebKit's media devices: the permission
and before it, the re-routing and that the real stream is stopped unseen, a denial and pinned
devices staying the engine's, the track's label, and a profile that does not use the device.

### Stage 3 (here): the image in the extension

The extension now draws the chosen **image** too (not only a colour or the test pattern), with
crop, fit and mirror, through CoreGraphics. The app writes the render settings to `camera.json` and
the image's bytes to `<group>/camera-image.bin` (`SystemCamera.writeRenderConfig`); the extension
loads the image (cached, reloaded when the file changes) and draws it each frame with the sensor
grain over it (`CameraFrameRenderer`).

### Stage 4 (here): the filters in the extension

The extension now applies the **filters** too (brightness, contrast, saturation, blur, hue, sepia,
invert, opacity, black-and-white), as a CoreImage chain matching the shim's CSS filters in the same
order (`CameraFilters`). The base frame is drawn into a scratch buffer, filtered into the output,
and the grain laid over it (`CameraFrameRenderer`). The editor shows the filters for both
deliveries now.

### Stage 5 (here): the video in the extension

The extension now draws a **video** source too, so the system camera matches the JavaScript shim
in full: colour, test pattern, image and video — each with crop, fit, mirror, the adjustments and
(for video) loop, freeze, speed and trim. `CameraVideoSource` decodes the clip headless with
`AVAssetReader` (no `AVPlayer`/run loop), on the one serial render queue: it reads the file the app
wrote to the app group, advances one or more frames per tick scaled by the speed, and re-opens the
reader at the trim start to loop. The app writes the video's bytes to `<group>/camera-video.<ext>`
and its playback settings to `camera.json`.

What a page reads is still gated per profile (`patchSystemCamera`); the frames are WebKit's own, so
a video delivered this way is indistinguishable at the JavaScript layer. The only limits left are
the ones above: the system camera is one global device (the last profile to launch with it sets
what it shows), and the gate takes effect once a page is granted the camera.

## Plan gating — a paid feature

Camera substitution belongs to the **pro** and **team** plans (`Entitlement.allowsCamera`: those
plans, or the server naming the `camera` feature, while the license is active). The gate is enforced
in two places, so a stored camera on a plan that does not open it never reaches a page:

- **The editor** shows the Camera part's settings only when `AppModel.allowsCamera`
  (`LicenseModel.allowsCamera`); below pro/team it shows just that it is a paid feature
  (`editor.camera.plan.*`), and nothing of the camera can be set.
- **At launch**, `ProfileManager` turns a profile's camera off (`cameraSubstitution = .off`) before
  the session's shim or the system camera's config is built, whenever `cameraAllowed()` is false.
  The parent reads the right from the license and carries it to a profile's own process through
  `PB_CAMERA_ALLOWED`; the child's manager (`ProfileSessionHost`) reads it back
  (`ProfileProcess.cameraAllowedForThisProcess`). Absent means allowed, so a development build
  (licensing off) and the self-test are not blocked.

The same shape as scenario automation (`allowsAutomation`, docs/AUTOMATION.md).

## Limitations

- In the JavaScript-shim path, the frames are drawn, not from a sensor. A check that watches for
  focus hunting, exposure changes or a real face/room can still tell. The system-camera path above
  is the answer to that.
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
