# VM Controller App

Swift controller that checks for Tart, clones a base image if needed, and launches a VM.

## Status

Basic implementation. Still requires Tart installed on the host.

## What it does

1. Checks that `tart` is available
2. Clones `ghcr.io/cirruslabs/macos-sonoma-base:latest` if the VM doesn't exist
3. Launches the VM

## What it doesn't do yet

- Bundle Tart (still needs `brew install`)
- Install the in-VM agent automatically
- Navigate Safari
- Proxy configuration
- UI

## Build and run

```bash
cd vm/controller-app
swift build
.build/debug/VMController https://browserleaks.com
```

Requires Tart: `brew install cirruslabs/cli/tart`
