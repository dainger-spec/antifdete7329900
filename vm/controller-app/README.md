# VM Controller App

Swift controller that checks for Tart, clones a base image if needed, and launches a VM.

## Status

Basic implementation. Still requires Tart installed on the host.

## What it does

1. Checks that `tart` is available (Homebrew bin dirs are added to `PATH`, so a
   GUI/minimal-PATH launch still finds it)
2. Clones `ghcr.io/cirruslabs/macos-sonoma-base:latest` if the VM doesn't exist
3. Launches the VM, installs the in-VM agent, and opens Safari at the URL —
   by delegating to `../controller/tart-prototype.sh`

Step 3 reuses the tested bash prototype instead of reimplementing the
boot → install agent → SSH tunnel → navigate flow. Ctrl+C reaches the script,
whose trap stops the VM and tears down the tunnel.

## What it doesn't do yet

- Bundle Tart (still needs `brew install`)
- Proxy configuration
- UI

## Build and run

```bash
cd vm/controller-app
swift build

# Run from the repo root so the controller can find tart-prototype.sh,
# or point $PB_TART_SCRIPT at it explicitly.
vm/controller-app/.build/debug/VMController https://browserleaks.com
# or:
PB_TART_SCRIPT=/path/to/vm/controller/tart-prototype.sh \
  .build/debug/VMController https://browserleaks.com
```

Requires Tart: `brew install cirruslabs/cli/tart`. Password auth to the stock
image also needs `sshpass` (`brew install sshpass`); key auth works without it.
