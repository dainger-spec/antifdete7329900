# PrivacyBrowser

**Status: architectural pivot in progress.**

The WKWebView-based prototype provides multi-profile isolation, encryption, and proxies. iOS-style profiles on public WKWebView have inherent platform limitations (telemetry, JS behavior, network stack). See `docs/ISOLATION_AND_LIMITATIONS.md`.

## New direction: VM-based Safari

Each profile runs in a separate macOS VM with genuine Safari.

- Design: [docs/VM_ARCHITECTURE.md](docs/VM_ARCHITECTURE.md)
- App with a window: `vm/controller-app/` — **VMLauncher.app** (see below)
- Prototype controller: `vm/controller/tart-prototype.sh`
- In-VM agent: `vm/agent/` (implemented — stdlib HTTP service that drives Safari)
- Slimming the VM (RAM/CPU caps, service disabling, measurement): `vm/slim.sh`, [vm/SLIMMING.md](vm/SLIMMING.md)
- Profiles on snapshots, cookies, fail-closed networking: [docs/PROFILES.md](docs/PROFILES.md)
- Hardware identity (hostname, MAC, platform limits): [docs/HARDWARE_IDENTITY.md](docs/HARDWARE_IDENTITY.md)

### Quick start (app)

```bash
vm/controller-app/scripts/build-app.sh
open vm/controller-app/build/VMLauncher.app
```

Create a profile (network: via proxy / direct / offline; time zone, language)
and press **Открыть браузер**: the app installs Tart if needed, downloads
macOS once, gives the profile its own system, serial number and MAC, and
opens real Safari in the app's own browser window — no Tart window, no macOS
desktop. Apple Silicon and macOS 14+ required. Details and a prebuilt zip
from CI: [vm/controller-app/README.md](vm/controller-app/README.md).

### Quick start (script)

```bash
# Install Tart
brew install cirruslabs/cli/tart

# Clone a base image
tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest safari-profile

# Run: boots the VM, installs the agent over SSH, tunnels to it, opens Safari
chmod +x vm/controller/tart-prototype.sh
./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com

# Save a screenshot too:
SHOT=/tmp/shot.png ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

The controller installs `vm/agent/pbagent.py` as a LaunchAgent in the VM,
opens an SSH tunnel to its loopback control port, then calls `POST /navigate`.
See [vm/agent/README.md](vm/agent/README.md).

## Previous prototype

The WKWebView app remains in `Sources/` for reference.

- Build: `scripts/build-app.sh`
- Docs: `docs/ARCHITECTURE.md`, `docs/ISOLATION_AND_LIMITATIONS.md`
