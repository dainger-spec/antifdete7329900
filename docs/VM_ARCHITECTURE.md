# VM Architecture

## Goal

Each profile runs in a separate macOS VM with real Safari.

## Why

Public WKWebView on macOS has platform-level differences from iOS Safari (telemetry, JS behavior, network stack, fonts, GPU). A real Safari inside a VM avoids these differences.

## Components

```
host (macOS)
├── controller/          # launches VMs, manages proxies, shows UI
├── images/              # base macOS images + snapshots
└── profiles/            # per-profile VM configs

VM (one per profile)
├── agent/               # small HTTP service controlling Safari
└── Safari               # real browser
```

## Runtime

- **Tart** (preferred on Apple Silicon) — lightweight, CLI, snapshot support.
- Alternative: UTM, vfkit.

## Flow

1. Controller starts a VM from a base image or snapshot.
2. Network is isolated; proxy is injected via VM config or agent.
3. Agent inside VM launches Safari to the target URL.
4. Controller can request screenshots or send input via the agent.
5. On stop, VM is snapshotted or discarded.

## Isolation

- One profile = one VM (or one snapshot).
- No shared cookies, storage, or state between VMs.
- Network egress only through the assigned proxy.

## Limitations

- RAM/CPU: a stock VM is heavy, but the RAM is a hard cap set on the host
  (`tart set --memory`), so it can be driven down — ~1.5–2 GB per VM with the
  base image slimmed (`vm/slim.sh`). Concurrency is still bounded by host RAM.
- Boot time: snapshots help, but not instant.
- Apple ID / iCloud inside VMs is manual.

## Status

Tart-based prototype in progress:

- **Launcher app** (`vm/controller-app/`, VMLauncher.app) — SwiftUI window:
  URL field, Start/Cancel, per-stage progress (Tart, image download with
  percent, VM, agent, Safari), errors in the window. Runs the controller
  script below rather than reimplementing it.
- **Controller** (`vm/controller/tart-prototype.sh`) — boots a VM, installs the
  agent over SSH, opens an SSH tunnel to the agent's loopback port, and drives
  Safari to a URL (with an optional screenshot).
- **In-VM agent** (`vm/agent/pbagent.py`) — **implemented**. Stdlib-only HTTP
  service with `/healthz`, `/status`, `/navigate`, `/screenshot`, `/quit`,
  bearer-token auth, and a pluggable Safari backend (`mac` via AppleScript /
  `screencapture`, `mock` for testing). Packaged as a LaunchAgent by
  `vm/agent/install.sh`. Tested on any platform via the mock backend
  (`vm/agent/test_pbagent.py`).

- **Slimming** (`vm/slim.sh`, `vm/measure-ram.sh`, docs in `vm/SLIMMING.md`) —
  RAM/CPU caps via `tart set` (wired into the controller as
  `VM_MEMORY`/`VM_CPU`/`VM_HEADLESS`, plus a `VM_RUN_ARGS` passthrough), an
  in-guest service-disabling + disk-cleanup script, and a memory meter.

Agent step 4 of the flow ("request screenshots or send input") currently covers
navigation and screenshots; richer input (clicks/typing) is future work.
