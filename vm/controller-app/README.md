# VM Controller App

Swift wrapper around VM management. Goal: user downloads the app, it handles the rest.

## Status

Stub. The working prototype is still `vm/controller/tart-prototype.sh`.

## Planned

- Bundle or download Tart/vfkit
- Download base macOS image on first launch
- Launch VM and install agent automatically
- Simple UI or menu bar app

## Build

```bash
cd vm/controller-app
swift build
.build/debug/VMController https://example.com
```
