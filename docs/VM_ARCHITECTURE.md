# VM Architecture

## Goal

Each profile runs in a separate macOS VM with real Safari. Sites see genuine WebKit, not a shimmed WKWebView.

## Why

Public WKWebView on macOS cannot emulate iOS Safari. Telemetry, JS behavior, network stack, fonts, and GPU all leak the host. A real Safari inside a VM does not have these contradictions.

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
- No shared cookies, storage, or fingerprints between VMs.
- Network egress only through the assigned proxy.

## Limitations

- RAM/CPU: each VM needs ~4 GB+. 10 concurrent VMs is heavy.
- Boot time: snapshots help, but not instant.
- Apple ID / iCloud inside VMs is manual.
- Hypervisor tells exist, but browser-level tells do not.

## Status

Design only. Implementation starts with a Tart-based prototype.
