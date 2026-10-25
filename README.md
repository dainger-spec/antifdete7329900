# PrivacyBrowser

**Status: architectural pivot in progress.**

The WKWebView-based prototype (multi-profile isolation, encryption, proxies, JS shims) reached its limit. iOS-profile emulation on public WKWebView is detectable by telemetry, JS behavior, and network stack. See `docs/ISOLATION_AND_LIMITATIONS.md`.

## New direction: VM-based real Safari

Each profile runs in a separate macOS VM with genuine Safari. Sites see a real browser, not a shimmed WKWebView.

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

## Old prototype

The WKWebView app remains in `Sources/` for reference. It is no longer the path for anti-detect use.

- Build: `scripts/build-app.sh`
- Docs: `docs/ARCHITECTURE.md`, `docs/ISOLATION_AND_LIMITATIONS.md`
