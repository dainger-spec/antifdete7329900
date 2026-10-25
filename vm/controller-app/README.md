# VMLauncher — Safari in a macOS VM, with a window

A small SwiftUI app: type a URL, press **Запустить**, and it brings up a macOS
VM with Tart, installs the in-VM agent and opens the URL in the VM's real
Safari, showing each step as it goes. The same package also has a command-line
controller (`VMController`).

| Stage | What happens | Progress shown |
|---|---|---|
| Проверка Tart | finds `tart` (PATH, Homebrew, or a copy the app downloaded) | spinner; if missing, a panel to install it |
| Образ macOS | `tart list`; if the VM is missing, `tart clone` of the base image | **percent** from tart's pull output |
| Запуск VM | boots the VM, waits for its IP and SSH | step text (IP once known) |
| Установка агента | copies `vm/agent` in over SSH, opens the SSH tunnel | step text |
| Открытие Safari | `POST /navigate` to the agent | step text |
| Готово | Safari shows the page in the VM window | — |

While a launch runs, **Запустить** is disabled and **Отмена** is enabled. Once
Safari is open the VM keeps running; **Остановить VM** (or quitting the app)
shuts it down. Errors appear in the window, with the full output in the
**Журнал** section below it (it expands on error and can be copied).

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
  the bar shows tart's own percentage.
- Tart opens the VM in its own window; Safari appears there.
- The stock Cirrus Labs image logs in as `admin` / `admin`; the app answers the
  SSH password prompt itself (no `sshpass` needed). For an image with other
  credentials, start the binary from a terminal with them set:
  `SSH_USER=… SSHPASS=… build/VMLauncher.app/Contents/MacOS/VMLauncher`.
- macOS may ask, inside the VM, to allow `python3` Screen Recording or
  Automation access — only for `/screenshot` and `/quit`, which the launch
  itself doesn't use.

## How it works

The app does not reimplement the launch: it runs the tested
`vm/controller/tart-prototype.sh` and maps its output (`==> Starting VM`, …)
onto the stages (`VMControllerCore/ScriptOutputParser.swift`; a test fails if
the script gains a heading the parser doesn't know). For a run without a
terminal it sets:

- `TART_NET=shared` — Tart's NAT network: `tart ip` finds the VM reliably and
  the host reaches it directly (the script's default stays `bridged`).
- `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` — a helper that answers the
  password prompt with `$SSHPASS`, since a GUI app has no TTY.
- `LOCAL_PORT` — a free port for the host end of the SSH tunnel.

The script runs in its own **process group**: Отмена signals the group the
way Ctrl+C does in a terminal, so the script's trap stops the VM at once
instead of after whatever `sleep`/`ssh`/`curl` it was waiting on. If it
doesn't exit, the app escalates to SIGTERM/SIGKILL and runs `tart stop` itself.

| Piece | Where |
|---|---|
| Stage model, script/tart output parsing, process groups | `Sources/VMControllerCore/` (builds and is tested on Linux too) |
| Window, Tart download/Homebrew install | `Sources/VMLauncher/` |
| Command-line controller | `Sources/VMController/` |
| Downloaded Tart, askpass helper | `~/Library/Application Support/VMLauncher/` |

## Troubleshooting

| Message | Meaning |
|---|---|
| Tart запускает macOS-VM только на Mac с Apple Silicon | Intel Mac: Tart can't run macOS guests there. |
| Не удалось скачать образ | Network or disk space; the log has tart's message. Fix it and press Запустить again. |
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
