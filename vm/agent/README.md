# In-VM Agent

A small HTTP service that runs inside each macOS VM and lets the host
controller drive the VM's real Safari.

## Responsibilities

- Accept commands from the host controller (HTTP over an SSH tunnel)
- Launch / focus Safari and navigate to a URL
- Return a screenshot or page status
- Quit Safari

## Status

**Implemented.** `pbagent.py` — Python 3.9+ standard library only, no
dependencies. Mirrors `server/pbsync_server.py`: `ThreadingHTTPServer`,
bearer-token auth (constant-time compare), careful request handling, and it
never logs headers or bodies.

## Endpoints

All but `/healthz` require `Authorization: Bearer <token>`.

| Method | Path          | Body                      | Result                         |
|--------|---------------|---------------------------|--------------------------------|
| GET    | `/healthz`    | —                         | `ok` (liveness, no auth)       |
| GET    | `/status`     | —                         | JSON: agent + Safari state     |
| POST   | `/navigate`   | `{"url":"https://…"}`     | opens/focuses Safari at `url`  |
| POST   | `/cookies`    | `{"cookies":[ … ]}`       | installs cookies into Safari   |
| GET    | `/screenshot` | —                         | `image/png` of the screen      |
| POST   | `/quit`       | —                         | quits Safari                   |

`/navigate` accepts only `http`/`https` URLs. The URL becomes a single argv
item of `open -a Safari` (no shell, no script text), so it cannot inject
commands or AppleScript.

## Safari backends

Safari is driven through a pluggable backend, selected with `--backend` or
`$PB_AGENT_BACKEND`:

- `mac` (default) — `open -a Safari <url>`, `pgrep`, `screencapture`. macOS only.
- `mock` — in-memory; lets the server be tested on any platform.

The `mac` backend avoids Apple Events for `/navigate` and `/status`: the first
`tell application "Safari"` from a new client shows an Automation consent
dialog inside the VM and blocks until someone clicks it. So `current_url` in
`/status` is the last URL the agent opened, not Safari's live front tab.
`/quit` still uses AppleScript (expect the consent dialog on first use), and
`/screenshot` needs Screen Recording permission for the agent's Python.

## Cookies

`POST /cookies` with `{"cookies": [ … ]}` (the normalized array from the app's
`CookieImport`, each cookie `{domain, name, value, path?, secure?, httpOnly?,
expires?}`) installs them into Safari. The `mac` backend quits Safari, writes
Safari's `Cookies.binarycookies` store (`binarycookies.py` encodes the format;
path overridable with `$PB_SAFARI_COOKIES`), so the next launch picks them up.
The encoder round-trips in tests; whether a given Safari accepts a hand-written
store (its sandboxed container path, permissions) is the one bit that needs a
real Mac — see docs/PROFILES.md.

## Install once, survives reboot

`install.sh` saves the bearer token to `~/.pbagent/token` and loads the agent
as a LaunchAgent (`RunAtLoad` + `KeepAlive`), so it restarts at every login —
after a reboot, with the VM set to auto-login, it is already running. The
controller reads `~/.pbagent/token` and **reuses an installed agent instead of
reinstalling** (`FORCE_INSTALL=1` forces a fresh install). So the agent is
copied and installed once per VM, not on every launch.

## Running

```bash
# Inside the VM (mac backend), token from the environment:
PB_AGENT_TOKEN=... python3 pbagent.py serve --host 127.0.0.1 --port 8777

# With no token, a fresh one is generated and printed once as
#   PB_AGENT_TOKEN=<token>
```

The agent binds to `127.0.0.1`. Reach it from the host through an SSH tunnel
(`ssh -L`); the controller sets one up automatically.

## Install as a LaunchAgent

Run `install.sh` inside the VM (the controller does this over SSH). It copies
`pbagent.py` to `~/.pbagent/`, writes
`~/Library/LaunchAgents/com.privacybrowser.agent.plist` from the template, and
(re)loads it so the agent starts now and at every login. The bearer token is
printed once on the last line as `PB_AGENT_TOKEN=<token>`.

```bash
./install.sh --port 8777 --backend mac   # token generated and printed
```

## Tests

```bash
python3 test_pbagent.py
```

Runs the real server against the `mock` backend, covering auth, routing,
URL validation, body handling, and every endpoint — on any platform.
