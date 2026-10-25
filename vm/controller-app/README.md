# Privacy Browser (VMLauncher) — real Safari, one macOS per profile

A SwiftUI app. Each **profile** is its own macOS virtual machine (cloned with
Tart) with real Safari: its own cookies, history and logins, its own network
mode, time zone, language, serial number and MAC. Pick a profile, press
**Открыть браузер**, and Safari opens in the app's own browser window — no
Tart window, no macOS desktop, no Apple boot screen.

**Main window**: profiles in the sidebar (+ «Новый профиль», import), the
selected profile's page with one button and what it is in plain words
(network, region, data). «Быстрый запуск» opens a page in a shared default
system with direct internet. **Settings (⌘,)**: browser-window mode, the base
macOS image and its updates, disk/RAM, and the log.

**Profile editor**: name; **Интернет** — *Через прокси* (fail-closed: only the
proxy is reachable; the proxy must be an IP), *Напрямую* (sites see this Mac's
IP), *Без интернета*; time zone and language (sites see both — match them to
the proxy's country); shared clipboard (off).

**Browser window**: the app's splash — your logo, the step, a progress bar
(and, on the first ~25 GB download, a carousel) — covers the VM while macOS
boots and the app sets it up; then the VM's screen appears, showing only
Safari: the Dock, menu bar and desktop are hidden in the guest
(`vm/guest-kiosk.sh`) and the agent keeps Safari's window filling the screen,
which follows the window's size. Closing the window stops the profile. The
first time, macOS in the profile asks once whether the agent may control
Safari (to size its window) — click «Разрешить».

How the VM is shown:

| Mode | When | What runs the VM |
|---|---|---|
| In the app's window (default) | the build has the virtualization entitlement (`build-app.sh` adds it), the VM is a standalone Tart VM | the app itself (`EmbeddedVM.swift`, Virtualization.framework) — NAT for *Напрямую*, the softnet helper started by the app for *Через прокси* / *Без интернета* |
| Tart's window (fallback) | the setting is off, `swift run` without the entitlement, a stacked clone, or the in-app start failed (logged) | `tart run`, from `tart-prototype.sh` |

Either way `tart-prototype.sh` does the in-guest part over SSH: identity
(hostname/time zone/language), the guest proxy, kiosk settings, the agent,
cookies, the page. While the app runs the VM it holds Tart's run lock on the
VM's `config.json`, so `tart list`/`tart ip` show it as running and
`tart run` can't start it twice.

A **menu-bar item** lists saved profiles (click to open one) and how many are
running. Profiles live in the JSON store (`VMController profiles …` on the
command line edits the same file).

## Requirements

- A Mac with **Apple Silicon** (Tart runs macOS guests only there), macOS 14+.
- About **60 GB free**: the base image download is ~25 GB and the VM disk is
  ~50 GB (sparse).
- **Tart** — not bundled. If it's missing the app offers to download the latest
  release from GitHub (signature checked, kept in
  `~/Library/Application Support/VMLauncher/tart/`), or to run
  `brew install cirruslabs/cli/tart`. Tart has its own license
  ([LICENSE](https://github.com/cirruslabs/tart/blob/main/LICENSE)); check it fits your use.
- To build: Xcode 15+ or the matching Command Line Tools.

The macOS image is never part of the app: it is pulled on first launch
(`ghcr.io/cirruslabs/macos-sonoma-base:latest` → a local VM named
`safari-profile`) and kept by Tart in `~/.tart`.

## Build the .app

```bash
vm/controller-app/scripts/build-app.sh          # → vm/controller-app/build/VMLauncher.app
ZIP=1 vm/controller-app/scripts/build-app.sh    # also build/VMLauncher.zip to share
```

`build-app.sh` runs `swift build -c release`, assembles the bundle
(`Contents/Resources/vm/` carries `tart-prototype.sh` and the agent files),
signs it ad hoc with the hardened runtime, and runs the app's `--self-check`
so a bundle that can't find its script or agent fails the build.
Options: `CONFIG=debug`, `APP_DIR=…`, `BUNDLE_ID=…`, `SIGN_IDENTITY=…`.

CI builds the same zip on every push: download the **VMLauncher** artifact
from the "VM launcher app (macOS)" job.

## Run

```bash
open vm/controller-app/build/VMLauncher.app
# or straight from source, without a bundle:
cd vm/controller-app && swift run VMLauncher
```

**An app downloaded as a zip** (e.g. the CI artifact) is only ad-hoc signed,
so Gatekeeper blocks the first launch. Right-click the app → **Open** → **Open**,
or `xattr -dr com.apple.quarantine VMLauncher.app`. To ship it to others
without that step, sign with a Developer ID and notarize:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ZIP=1 vm/controller-app/scripts/build-app.sh
# build-app.sh signs with --timestamp=none; notarization needs a timestamp, so re-sign first:
codesign --force --options runtime --timestamp --sign "Developer ID Application: …" build/VMLauncher.app
ditto -c -k --keepParent build/VMLauncher.app build/VMLauncher.zip
xcrun notarytool submit build/VMLauncher.zip --keychain-profile <profile> --wait
xcrun stapler staple build/VMLauncher.app
```

## What to expect on the first launch

- The image download takes a while (tens of minutes, depending on the line);
  the bar shows tart's own percentage. A new profile is a clone of that image
  (seconds, copy-on-write) and gets its own serial number and MAC right away.
- Safari appears in the app's browser window (or, in the fallback, in Tart's
  window).
- The stock Cirrus Labs image logs in as `admin` / `admin`; the app answers the
  SSH password prompt itself (no `sshpass` needed). For an image with other
  credentials, start the binary from a terminal with them set:
  `SSH_USER=… SSHPASS=… build/VMLauncher.app/Contents/MacOS/VMLauncher`.
- macOS asks once, inside the profile, to let `python3`/`osascript` control
  Safari — that's the agent keeping Safari full-size; allow it. Screen
  Recording is only for `/screenshot`, which the launch doesn't use.

## How it works

The app does not reimplement the launch: it runs the tested
`vm/controller/tart-prototype.sh` and maps its output (`==> Starting VM`, …)
onto the stages (`VMControllerCore/ScriptOutputParser.swift`; a test fails if
the script gains a heading the parser doesn't know). For a run without a
terminal it sets:

- `TART_NET` / `SOFTNET_ALLOW` from the profile's network mode (`shared` for
  direct, `softnet` + the proxy's /32 for the fail-closed modes); the
  script's own default stays `bridged`.
- `VM_EXTERNAL=1` when the app runs the VM itself, `KIOSK=1`,
  `IDENTITY_PROFILE` (the profile id — the hostname seed),
  `IDENTITY_TIMEZONE`/`IDENTITY_LANGUAGE`, `PROXY_URL` (guest proxy),
  `COOKIES_FILE` only after a new cookie import.
- `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` — a helper that answers the
  password prompt with `$SSHPASS`, since a GUI app has no TTY.
- `LOCAL_PORT` — a free port for the host end of the SSH tunnel.

For the script on its own, the VM runs **headless** by default
(`--no-graphics`, `VM_HEADLESS=0` shows Tart's window); the app's fallback
mode shows Tart's window, since that is where Safari is then.

To shrink the VM's footprint, set `VM_MEMORY` (MiB) and `VM_CPU` when running
`tart-prototype.sh` (the app does not set them). They map to
`tart set --memory/--cpu`. See
[vm/SLIMMING.md](../SLIMMING.md) for a stable minimum (~1536 MiB) and the
in-guest service-disabling (`vm/slim.sh`) and measurement scripts.

The script runs in its own **process group**: Отмена signals the group the
way Ctrl+C does in a terminal, so the script's trap stops the VM at once
instead of after whatever `sleep`/`ssh`/`curl` it was waiting on. If it
doesn't exit, the app escalates to SIGTERM/SIGKILL and runs `tart stop` itself.

| Piece | Where |
|---|---|
| Stage model, script/tart output parsing, process groups | `Sources/VMControllerCore/` (builds and is tested on Linux too) |
| Window, browser window, in-app VM, Tart download/Homebrew install | `Sources/VMLauncher/` |
| Your logo / app icon | `Resources/Brand/` (see its README) |
| Command-line controller | `Sources/VMController/` |
| Downloaded Tart, askpass helper | `~/Library/Application Support/VMLauncher/` |

## Troubleshooting

| Message | Meaning |
|---|---|
| Tart запускает macOS-VM только на Mac с Apple Silicon | Intel Mac: Tart can't run macOS guests there. |
| Не удалось скачать образ | Network or disk space; the log has tart's message. Fix it and press «Открыть браузер» again. |
| VM не получила IP-адрес | The VM didn't boot far enough; look at the VM window. |
| Не удалось подключиться к VM по SSH | Wrong `SSH_USER`/`SSHPASS` for this image, or Remote Login is off in the VM. |
| Агент в VM не отвечает через SSH-туннель | `python3` missing in the VM, or the agent crashed: see `~/.pbagent/agent.log` inside the VM. |

## Command line

```bash
cd vm/controller-app
swift run VMController https://browserleaks.com
```

Same flow without the window: checks Tart, clones the image if needed, then
runs `tart-prototype.sh` attached to the terminal (Ctrl+C stops the VM).

## Tests

```bash
cd vm/controller-app && swift test
```

Covers the stage model, `tart` progress parsing, and runs the real
`tart-prototype.sh` against stub `tart`/`ssh`/`scp`/`curl` through the same
process-group runner the app uses — including cancelling it mid-launch. They
run on Linux and macOS (where the script runs under the system bash 3.2).

## When the VM never gets an IP

`tart-prototype.sh` polls `tart ip` for `IP_TIMEOUT` seconds (default 120),
printing `still waiting for VM IP (Ns of 120s, TART_NET=…)` every 10 s — the
app shows it as «Ожидание IP-адреса VM: N из 120 с…». It now stops early and
says why instead of waiting:

| Log line | Meaning |
|----------|---------|
| `tart run exited before the VM got an IP (code N, …)` | `tart run` failed at start; its own error is the line above. Typical: the VM is already running, two macOS VMs already run (Apple's limit per host), softnet failed to start. |
| `softnet not found …` | A profile runs over softnet (`TART_NET=softnet`); install it: `brew install cirruslabs/cli/softnet`. |
| `softnet needs root once; run in Terminal: …` | softnet is neither setuid-root nor allowed by passwordless sudo; tart would ask for a password on a terminal the app doesn't have and die. Run the printed command once. |
| `fail-closed networking needs a newer tart/softnet …` | Fail-closed needs tart ≥ 2.30 and softnet ≥ 0.22; the controller refuses to run a profile open. See [docs/PROFILES.md](../../docs/PROFILES.md#fail-closed-networking). |
| `Could not configure the proxy in the VM …` | `vm/guest-proxy.sh` failed in the guest (output above); the profile VM can reach only its proxy, so the launch stops. |
| `Failed to get VM IP after Ns (TART_NET=…)` | The VM runs but got no DHCP lease. Followed by a hint for the network mode and the list of running VMs. The in-app browser window shows the VM only once Safari is ready; to watch the boot, turn off «Показывать браузер в окне приложения» in Settings (Tart's window then shows the whole guest). |
| `warning: '<vm>' has the same MAC …` | Two VMs share a MAC (e.g. a profile imported next to its source): one DHCP lease for both. Fix: `tart set <vm> --random-mac`. |

How the address is found: `shared` and `softnet` VMs get it from the host's
DHCP server (`/var/db/dhcpd_leases`, which `tart ip` reads); `bridged` VMs get it
from the LAN and are found via ARP on `BRIDGE_IF`.

Plain launches use `shared` and profiles use `softnet`, so a plain launch
working while a profile hangs usually points to softnet.

**Two VMs at once:** Virtualization.framework allows at most two macOS guests
per host. The script can run two (each gets its own lease on shared/softnet),
but the app drives one launch at a time: stop the running VM before starting
another profile.

