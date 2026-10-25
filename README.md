# PrivacyBrowser

**Status: architectural pivot in progress.**

The WKWebView-based prototype provides multi-profile isolation, encryption, and proxies. iOS-style profiles on public WKWebView have inherent platform limitations (telemetry, JS behavior, network stack). See `docs/ISOLATION_AND_LIMITATIONS.md`.

## New direction: VM-based Safari

Each profile runs in a separate macOS VM with genuine Safari.

- Design: [docs/VM_ARCHITECTURE.md](docs/VM_ARCHITECTURE.md)
- Prototype controller: `vm/controller/tart-prototype.sh`
- In-VM agent: `vm/agent/` (placeholder)

### Quick start (prototype)

```bash
# Install Tart
brew install cirruslabs/cli/tart

# Clone a base image
tart clone ghcr.io/cirruslabs/macos-sonoma-base:latest safari-profile

# Run
chmod +x vm/controller/tart-prototype.sh
./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

## Previous prototype

The WKWebView app remains in `Sources/` for reference.

- Build: `scripts/build-app.sh`
- Docs: `docs/ARCHITECTURE.md`, `docs/ISOLATION_AND_LIMITATIONS.md`
