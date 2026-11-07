# Lumen for iPhone — stage 1 measurements (never merged)

Branch `claude/ios-app-measure`. Measurements only: no product code. Each claim in the report
(`ios-measure/REPORT.md`) is marked **measured**, **read in code** or **from documentation**.

## What is here

| | |
|---|---|
| `app/` | The measurement driver: an iOS app of WKWebViews that does what the harness tells it (sessions with a data store and proxies, loads, scripts, cookies). It decides nothing itself. |
| `build_sim_app.sh` | Builds it for the iOS Simulator with `swiftc` (no Xcode project). |
| `host/harness.py` | The Mac side: proxy A (HTTP, Basic auth), proxy B (SOCKS5, user/password), a proxy killed mid-run, a dead port, the "site" (HTTP, HTTPS, WebSocket), STUN, a DNS capture; scenarios and checks. |
| `host/fake_driver_chromium.mjs` | A stand-in driver on Chromium, to test the harness itself on Linux. Proves nothing about iOS. |
| `run_sim.sh` | Builds, boots a simulated iPhone per runtime, runs the red runs and the green one. |
| `.github/workflows/ios-app-measure.yml` | The same on GitHub's macOS images (Xcode 15.4 … 27.1, iOS 17 … 27.1). |

## Red before green

`--brk` breaks the setup on purpose: `noproxy` (sessions A and B get no proxy), `swap` (each gets the
other's proxy), `sharestore` (both on one data store). Each must make the core checks FAIL; only then
the green run counts. `run_sim.sh` prints `RED OK …` / `RED DID NOT FAIL …` and `GREEN …`.

## On a Mac (the owner)

```sh
git fetch origin claude/ios-app-measure && git checkout claude/ios-app-measure
ios-measure/run_sim.sh ~/lumen-measure q1 newest     # asks for sudo: lo0 aliases, tcpdump
```

The real iPhone: see `ios-measure/DEVICE.md`.
