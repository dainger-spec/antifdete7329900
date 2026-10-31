// Docs: “Proxies: setup and failure”. Written from the browser's code and the measurements in the repository (the product branch
// claude/secret-partner-setup-e505tc at 194828b); where behaviour isn't confirmed by the code or a measurement — a
// {{unv:…}} mark, not a guess. The source of every statement: design/site/docs-sources/docs-proxy.md.
export default {
  title: 'Proxies: setup, and when one fails',
  lead: 'Set and check a profile\'s proxy, and see what happens when it fails: pages do not go around it.',
  toc: [['types', 'Proxy types'], ['where', 'Setting a proxy'], ['list', 'List and checks'], ['location', 'Time zone and language'], ['traffic', 'DNS, WebRTC, UDP'], ['failure', 'When the proxy fails']],
  body: `## Proxy types {#types}

SOCKS5 and HTTP, with or without a login. HTTPS is an HTTP proxy reached over TLS {{unv:no test loads anything through an HTTPS proxy}}.

## Setting a proxy {#where}

In the profile editor (**⋯ → Edit…**), **Connection** offers **No Proxy**, **From the List** and **New**. Under **New**, paste the proxy as the provider gave it: \`host:port:user:pass\`, \`user:pass@host:port\`, \`socks5://user:pass@host:port\` or \`host:port\`. The scheme sets the type: \`socks5://\` (or \`socks5h://\`, \`socks://\`), \`http://\`, \`https://\`.

Without a scheme, **Check** or **Save** finds the type; with none found, nothing is saved.

**Bypass domains (comma-separated)** takes domains out of the proxy {{unv:that they then go out directly is not measured}}. Changes apply at the next launch. More: [creating a profile](docs-profile.html).

## List and checks {#list}

The list is under **Proxies** in the Profiles window's sidebar, encrypted, on this Mac only; each profile keeps its own copy.

- **Add** takes one proxy in the same field; **Import…** takes a list, pasted or **From File…**, one per line, with text after \` #\` as its name. Unreadable lines are listed with the reason; repeats (same host, port and user name) are skipped. By default, lines without a scheme get their type at the first check; no profile gets them before.
- **Assign to Profiles…** — one proxy for all ticked profiles, or several in turn, round-robin. A running profile keeps its proxy until it stops.
- **⋯ → Edit…** reaches the profiles using the proxy; **⋯ → Export…** writes user names and passwords in plaintext.

**Check All** and **Check Selected** test each proxy through itself: **Address**, **Connection**, **Handshake** as SOCKS5 and HTTP, **Login**, **Tunnel**, **Through the proxy** (a geolocation request). Never directly. A working proxy shows its country, city, exit IP, network and latency (median of three tunnels); the selected one, a report with **What to do**. Checks run only on request.

## Time zone and language {#location}

At launch the profile asks a geolocation service through the proxy (ipinfo.io, then geojs.io, ipwho.is and ipapi.co), which sees the proxy's address, not this Mac's. The profile takes the exit's time zone and its country's language, such as \`de-DE\` for Germany: **Time zone and language → From the connection** in **Location and Language**, the default.

The answer is awaited up to three seconds, or a second if the exit is known. If no service answers, the profile keeps its last launch's time zone and language, or this Mac's, and {{name}} says so. With **Each profile its own app in the Dock** off, the first profile launched sets the language for the run. Rotating proxies: **Warn when the proxy's IP changes**.

## DNS, WebRTC, UDP {#traffic}

- **DNS.** The proxy, SOCKS5 or HTTP, resolves site names itself. This Mac looks up only the proxy's address; DNS prefetching is blocked.
- **WebRTC** is off with a proxy, whatever the setting: its UDP would go around it.
- **QUIC (HTTP/3)** is not used: pages go through the proxy over HTTP/2, and a profile in its own process may send no UDP.
- **This Mac's addresses** (\`127.0.0.1\`, \`localhost\`) are closed to pages; local-network ones go through the proxy.

Only two settings lead around the proxy: **Bypass domains (comma-separated)** and **Safe Browsing (lookups bypass the proxy)**, both inactive by default. The app's own sync and [update](docs-updates.html) check go out directly.

In the latest registered CI run, none of the 2,410 packets captured during the self-test went around the proxy {{unv:measured with test proxies on the same Mac, never a remote one}}.

## When the proxy fails {#failure}

While the proxy is down, pages do not load: {{name}} never falls back to a direct connection. The CI self-test checks this with unreachable and unresolvable proxies.

**Not started.** An unusable proxy address, or an HTTP proxy wanting a login the profile lacks (seen when the launch looks up the exit), stops the launch: “…The profile was not started, so no site opens directly.” {{unv:by the code, a profile in its own process does not show this message}} If found later, the profile is stopped.

**Started, proxy not working.** At launch {{name}} asks the proxy itself once; if it fails, the Profiles window shows **“…” loads no pages**, the report, **Check Proxy** and **Show in Proxies**. In **Settings → Proxies → A proxy that does not work**, **Do not start the profile** keeps such a profile stopped; the default is **Start the profile, say why**.

**Fails mid-session.** Pages stop loading; the app's window shows **Page could not be loaded** and the reason {{unv:what Safari's own window shows here}}. The Profiles window says nothing: the proxy is asked only at launch.

| State | What to do |
|---|---|
| **Host not found** | Check the address for a typo |
| **Connection refused** | Wrong port, or the service is stopped |
| **Silent after connecting** | Whitelist this Mac's IP, or use a login |
| **Needs a login**, **Login rejected** | Copy the login from the provider's dashboard |
| **Refuses this Mac** | Add this Mac's IP with the provider |
| **No way out** | Check later, or ask the provider |
| **VPN's substitute DNS** | Check with the VPN off |

To recover, click **Check Proxy**: if it works, reload the page, or reopen the profile if the type was corrected; if not, fix the proxy (**⋯ → Edit…**) or assign another and relaunch. More: [what to do when something fails](docs-trouble.html).`,
};
