# Local automation API

A script on this Mac can do what the Profiles window does with a profile: list the profiles, start
one (with its window or out of sight), open a page in it, read and write its cookies, stop it. It
goes through the same code as the app's own buttons (`AutomationHandler` → `ProfileManager`), so a
profile started from a script is the profile started from the list: its proxy, its own process,
its time zone and language, and its data sealed again when it stops.

It is **off** until turned on in **⋯ (in the Profiles window) → Automation API…**, and only in the
build without the App Sandbox (`SANDBOX=0 scripts/build-app.sh`): the sandboxed build is not
allowed to accept connections. It listens only while the vault is unlocked.

## Who can reach it

| | |
|---|---|
| Address | `127.0.0.1` and the port chosen (50777 by default). Bound to the loopback interface: no other machine can connect. |
| Token | Every request carries `Authorization: Bearer <token>`. The token (43 characters, random) is shown in the same window, with **Copy** and **New Token**; it is kept encrypted in the vault's device settings and never synced. Anyone who has it can start the profiles and read their cookies: keep it like a password. |
| Web pages | A request that carries `Origin` or any `Sec-Fetch-*` header — every request a browser makes for a page to another origin does — is refused before the token is looked at, and no answer carries a CORS header. A page that points a name of its own at 127.0.0.1 (DNS rebinding) is refused by the `Host` check: only `127.0.0.1:<port>`, `localhost:<port>` and `[::1]:<port>` are answered. |
| What answers hold | A profile's proxy is shown as `socks5://host:port` or `http://host:port`, never with its username or password. Cookies — a session's secret — only from the cookie endpoint, when asked for by name. |

One request per connection (`Connection: close`); bodies up to 8 MB, with a `Content-Length`.

## Requests

A profile is named in the path by its id or by its exact name (URL-encoded); a name that two
profiles share is refused (`409 ambiguous`) — use the id.

| Request | What it does | Answer |
|---|---|---|
| `GET /v1/profiles` | Every profile | `[Profile]` |
| `GET /v1/profiles/{profile}` | One profile | `Profile` |
| `POST /v1/profiles/{profile}/start` | Starts it; body `{"window": false}` starts it out of sight (as a warm-up does), default `true`. A running profile is left as it is. | `Profile` |
| `POST /v1/profiles/{profile}/stop` | Stops it; its data is sealed before the answer comes. | `Profile` |
| `POST /v1/profiles/{profile}/open` | A new window of the running profile on `{"url": "https://…"}` (http or https only) | `Profile` |
| `GET /v1/profiles/{profile}/cookies?format=…` | Every cookie of the profile, session cookies included: `playwright` (default; Puppeteer's `page.setCookie` takes it too), `netscape` (`cookies.txt`), `extension` (EditThisCookie / Cookie-Editor). A stopped profile is started out of sight, read and stopped. | the file |
| `POST /v1/profiles/{profile}/cookies` | Imports the body — any cookie file the app imports (JSON or Netscape). Into the store at once when the profile runs, else queued, encrypted, for its next launch. | `{"applied": n, "refused": n}` or `{"queued": n}`, and `leftOut` |

```json
{
  "busy" : false,
  "id" : "6B0E3C1F-…",
  "lastLaunchedAt" : "2026-10-29T12:00:00Z",
  "name" : "Shop DE",
  "proxy" : "socks5://de.gw.example:1080",
  "running" : true
}
```

Errors are `{"error": "<code>", "message": "<text>"}`: `401 unauthorized`, `403 forbidden`,
`404 not_found`, `405 method_not_allowed`, `400 bad_request`, `409 ambiguous` / `launch_failed` /
`not_running` / `busy`, `411`, `413`, `431`.

## From a script

```sh
export PB_API_TOKEN='…'          # from Automation API… → Copy
curl -s -H "Authorization: Bearer $PB_API_TOKEN" http://127.0.0.1:50777/v1/profiles
curl -s -X POST -H "Authorization: Bearer $PB_API_TOKEN" -d '{"window": false}' \
     http://127.0.0.1:50777/v1/profiles/Shop%20DE/start
curl -s -H "Authorization: Bearer $PB_API_TOKEN" \
     'http://127.0.0.1:50777/v1/profiles/Shop%20DE/cookies?format=netscape' > cookies.txt
```

`scripts/pbctl` does the same from the command line (Python 3, nothing to install):

```sh
scripts/pbctl list
scripts/pbctl start "Shop DE" --hidden
scripts/pbctl open "Shop DE" https://example.com/
scripts/pbctl cookies "Shop DE" --format playwright > state-cookies.json
scripts/pbctl import-cookies "Shop DE" cookies.txt
scripts/pbctl stop "Shop DE"
```

It reads the token from `PB_API_TOKEN` and the port from `PB_API_PORT` (default 50777).

## What it does not do

It does not drive the pages themselves: there is no remote-debugging protocol for WebKit's
embedded web views to hand out, as Chromium-based browsers hand out CDP for Puppeteer or
Playwright to attach to. A script starts the profile, opens the page and takes the cookies; what
happens on the page is the person's, or a warm-up's (**⋯ → Warm Up…**).

## Checked

Unit tests (`AutomationAPITests`): the request reader, the gate (token, `Host`, `Origin` and
`Sec-Fetch-*`), the routes, a profile found by id or exact name, no credentials in an answer. The
self-test, on a real listener: no token, a wrong token, a web page's request and a rebinding name
refused; the list without the proxy's credentials; a profile started out of sight, a cookie
imported into it and read back out, a `file:` address refused, the profile stopped; nothing
answering once the API is off. The sandboxed build: does not listen, and says why.
