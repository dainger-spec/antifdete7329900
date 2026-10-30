# Leak audit: the short list

What the leak audit of 2026-10-29 found (one auditor per channel, then a skeptic per finding:
77 agents, stopped by the runtime before it finished; its results are in the session, not in the
repository). Agents verify by reading code; a network leak is verified by measuring. So this list
keeps only what a measurement can settle, and says for each what the measurement is.

**Kept** — all three at once:
1. the channel is open to a profile with a proxy whose window is Safari's chrome (the main path);
2. it can be reproduced on the CI runner (macOS 26) or with one command on the owner's Mac
   (macOS 27.0.1, Safari 27);
3. its consequence is this Mac's IP or the person's identity, not a local trace on disk.

**Proof** is one of: a request in the self-test proxy's log (`scripts/selftest_proxy.py`, hosts on
`.invalid` / `leak.example.com` that only the proxy answers), a connection taken by its loopback
canary, a packet in the pktap capture (`scripts/egress_check.py`), a line of
`log stream --predicate 'subsystem == "PrivacyBrowser"'`, or a file. "CI 382" is run 40915070998
(commit 6297e12, macOS 26, WebKit 21624.5.1.11.3), the latest measured.

## 1. A web view of Safari's chrome off the profile's store (the leak the owner saw)

| | |
|---|---|
| Channel | The page itself, and everything it loads, from this Mac's IP: a web view built with a data store that has no proxy. |
| Why reachable here | Safari's chrome builds web views from `+[WebKitPreferencesManager …]` configuration factories, which `SafariChromeHost` patches by name, **and builds its content web view without them**. Established on macOS 27.0.1 / Safari 27 (owner, 2026-10-29): the factories are there — `Safari's configuration factories patched: contentWebViewConfigurationForBrowsingMode, …, readerWebViewConfigurationForBrowsingMode` — so the earlier hypothesis that Safari 27 renamed them is **wrong**; and still `[Error] [ProfileNetworkGuard] A web view reached its initializer without the profile's store (Safari's factories missed it); given the profile's now`. The content web view gets the profile's store **only** from `ProfileNetworkGuard.everyWebViewGetsTheProfilesData`, which hooks `-[WKWebView initWithFrame:configuration:]` and `-[WKWebView _initializeWithConfiguration:]` (names of WebKit, not of Safari); WebKit's default store is replaced by a closed one. Without that hook this web view is on a store with no proxy: **that is the leak the owner saw on macOS 27.** The same happens on macOS 26 (CI 382 below). |
| Proof | CI 382: `PASS Safari chrome: every web view of the process is on the profile's store, with its proxy`; the report says `webViewsCaughtByNet: 1` — on macOS 26 too Safari's factories missed the chrome's web view and only the initializer hook gave it the profile's store. **macOS 27.0.1, measured by the owner (2026-10-29)**, the run below with a profile on HTTP CONNECT `127.0.0.1:18080` (`scripts/selftest_proxy.py --http 18080`): `http://proxied.selftest.invalid/check` → `PB-PROXY-OK via=connect target=proxied.selftest.invalid:80 path=/check` (a name that resolves nowhere: it could only load through the proxy), `http://example.com/` → `PB-PROXY-OK via=connect target=example.com:80 path=/` (an ordinary name: no way around the proxy for real addresses either); the log: `Profile: has a proxy=true store proxies=1`, the factories patched, the initializer line above, `A web view is up: proxies=1` four times, not one `is NOT on the profile`. |
| Close / cost | Closed in code (initializer hooks, closed default store, a web view off the profile loads nothing), **verified on macOS 27 by the owner** — with a local proxy. Measured only through a proxy on this Mac (the vendor's proxy, `54.194.87.51:62804`, was dead: TCP opens, no SOCKS5 or HTTP handshake, `curl` exit 28 by timeout both ways); a remote proxy over the internet on macOS 27 is **not measured** yet. With this verified, a process per profile is on by default in the unsandboxed build (e496808, held until this run as d7f9284). |

## 2. Requests to this Mac (127.0.0.1, localhost, ::1) — measured open, fixed in this commit

| | |
|---|---|
| Channel | A page's fetches, frames and workers to this Mac's own addresses go directly, never through the proxy. A page probes which local ports are open: the same set in every profile, so it links the profiles to one machine (identity, not the public IP). |
| Why reachable here | The system never sends loopback through a proxy (`WKWebsiteDataStore.proxyConfigurations` / `ProxyConfiguration` have no setting for it). |
| Proof | CI 382: `FAIL … a fetch to 127.0.0.1 / localhost / ::1 goes through the profile's proxy`, and the canary listener on the runner logged `127.0.0.1:18087 GET /pb-leak/lo4`, `::1:18087 GET /pb-leak/lohost`, `/pb-leak/lo6`. |
| Close / cost | WebKit's content blocker in every proxied profile's web views (`ProxiedContentRules`, compiled by `ContentRules`): every load to 127.0.0.0/8, `localhost`, `*.localhost`, `::1`, its IPv4-mapped form, `0.0.0.0`, `::` is blocked unless the page itself is on this Mac. Check in the same commit: the leak page's fetches to all of them, a frame on 127.0.0.1 and a worker's fetch are `rejected`, and the canary takes no connection. **Closed — CI 383** (7c9c7eb): `PASS … a page cannot reach this Mac (127.0.0.1, localhost, ::1, 0.0.0.0, from the page and from a worker): each is refused`, `PASS … nothing reached this Mac directly`. A private-network address (10.255.255.1) was measured going through the proxy, and is checked so from then on. Cost: a page of a proxied profile cannot reach a local service (a dev server, a local wallet bridge) unless the user opens it as a page. Not covered: a remote HTTPS site's service worker (not provable now, see the deferred list). |
| Must stay so | **The block and a proxy on this Mac coexist** — established on macOS 27.0.1 (owner, 2026-10-29): a profile whose proxy is HTTP CONNECT `127.0.0.1:18080` loads its pages through it (item 1's two pages). The rule stops what a *page* loads from loopback; the data store's own connection to its proxy is not a page load and is not touched. Any later widening must keep that: a rule that cut the profile's process off from loopback as a whole (a kernel or sandbox closure, a broader content rule, a port filter) would break every proxy on this Mac — an `ssh -D` port, a local proxy chain, the self-test proxy CI proves this list with. Measured with a local proxy only. |

## 3. A certificate that makes the system fetch (AIA / OCSP) — critical in the audit

| | |
|---|---|
| Channel | trustd fetches a missing intermediate (AIA) or an OCSP answer named in a page's certificate, from this Mac's IP, outside the proxy; a page can name a URL unique to the visitor. |
| Why reachable here | Server trust left to the system's default handling, in our tabs, in Safari's navigation delegates, the store's delegate (service workers) and URL sessions. |
| Proof | CI 382: `PASS … an HTTPS image whose certificate needs a fetch reached the proxy, and its certificate was refused`; the egress capture saw no packet with the canary names (`pbaiacanary`). **The control is not seen**: the capture never showed the control fetch (`pbaiacontrol`, made on purpose by a profile without a proxy), so the capture's ability to see trustd's fetch is unconfirmed (`##[warning] … inconclusive`). |
| Close / cost | Closed in code (`ServerTrust`: evaluation with network fetches off, untrusted chains refused, every challenge path). The proof is partial until the control is seen. |
| Reopened — CI 413 | The capture saw the canary: `A? pbaiacanary.leak.example.com`, asked by mDNSResponder for the app's own process while a proxied profile loaded that certificate in our own tab (the load itself went through the proxy and the certificate was refused). Cause, in Security's SecTrust.c: fetching off is kept as an option of the trust's *policies* (`kSecPolicyCheckNoNetworkAccess`), and `ServerTrust.evaluate` turned it off *before* `SecTrustSetPolicies`, which replaces the policies — so trustd was allowed to fetch. Runs 382–412 showed no such query; why trustd fetched in 413 and not before is not known: the order was wrong all along. |
| Fixed | `ServerTrust.evaluate`: the SSL policy first, then fetching off; the trust is then asked (`SecTrustGetNetworkFetchAllowed`) and one that still says it may fetch is refused unevaluated. Checks in the same commit: `PASS certificates: every trust evaluated says itself it may not fetch …` (our tabs), and the Safari-chrome profile's process reports `trustFetchAllowed` 0 (`PASS Safari chrome: certificates are checked without fetching …`). The capture's canary check stays the end-to-end proof. |

## 4. QUIC / UDP outside the proxy

| | |
|---|---|
| Channel | HTTP/3 and any UDP from this Mac's IP (Network.framework ignores a privacy context's proxies for QUIC). |
| Why reachable here | Safari's frameworks run clients of their own in the profile's process. |
| Proof | CI 382: `PASS Safari chrome: UDP is closed to the profile's process` (a UDP datagram and a QUIC connection to documentation addresses refused, `report.udp`), and the egress capture: `nothing went around the profile's proxy`. `scripts/leak_check.py`: `QUIC: stays on the proxy` for HTTP and SOCKS5 profiles (in our own windows). |
| Close / cost | Closed: the kernel denies the profile's process every outgoing UDP datagram when it has a proxy, and the process does not start otherwise (`closeTheProcess`, fail-closed since 63642e4). |

## 5. WebRTC (STUN) from this Mac's IP

| | |
|---|---|
| Channel | ICE candidates gathered on this Mac's interfaces; a STUN server learns the real IP. |
| Why reachable here | Safari's chrome builds web views with Safari's preferences, and WebRTC can be turned on by `-[WKPreferences _setEnabled:forFeature:]` (`PeerConnectionEnabled`) as well as its own setter. |
| Proof | CI 382: `PASS … WebRTC is off in Safari's web views (page, frame, about:blank frame)`, `PASS … no web view of the process has WebRTC in its engine`, `PASS … nothing the profile has off can be turned on again by another setter`. |
| Close / cost | Closed (every setter pinned; the report tries each one). |

## 6. WebTransport in workers

| | |
|---|---|
| Channel | QUIC from a shared or service worker, which copies the preferences of the process's first web view rather than the page's. |
| Why reachable here | WebKit's remote-worker preferences. |
| Proof | CI 382: `PASS … WebTransport and WebRTC are absent in a secure context (page, worker, shared worker)`. **The service-worker half was vacuous**: the test took the page's own report (`"sw": "registered"`) for the service worker's; it now takes the service worker's (`"sw": true`) and fails when there is none, and every worker must have answered `undefined` (a timeout no longer passes). |
| Close / cost | In a profile's process: the process's first web view is a closed template with these features off, and each store carries the profile's preferences for its service workers. In the manager's process (profiles in our own windows) the template is gone: measured in CI 383, it kept a stopped profile's session alive (its session cookie came back at the next launch; without the template every cookie check passed, without the per-store preferences they did not). What those profiles' workers get without it is a new check: a proxied profile's page, dedicated, shared and service worker on a page of this Mac, after profiles without a proxy have had theirs. |

## 7. DNS from this Mac (dns-prefetch)

| | |
|---|---|
| Channel | A page's `<link rel=dns-prefetch>` resolved by this Mac's resolver, outside the proxy. |
| Why reachable here | WebKit skips prefetch only for a system-wide proxy; from WebKit 7621 it is a `ping` load, before that a preference. |
| Proof | CI 382: `PASS … <a ping> is blocked in Safari's web views (and dns-prefetch with it)`; the egress capture fails on any DNS question for a leak page name and saw none. |
| Close / cost | Closed (the rule list, kept on when Safari turns content blockers off; the preference off and pinned). |

## 8. Safari's own services in other processes

| | |
|---|---|
| Channel | Search suggestions, OpenSearch, Safe Browsing, Siri Suggestions, translation, Apple Pay, iCloud Keychain AutoFill, sharing — fetched by XPC services as this Mac. |
| Why reachable here | Safari's chrome connects to them from the profile's process (`NSXPCConnection`). |
| Proof | CI 382: `PASS … Safari's own services are set as the profile needs them`; the report lists every service the process connected to, the refused ones marked; the egress capture fails on any packet of those services in the window and saw none. **Partial**: the self-test never types into the address bar, so suggestions are not driven, only refused. |
| Close / cost | Closed by refusal (`noServiceOutsideTheProxy`, a deny list) and Safari's settings. An allow list instead needs the list of services the chrome uses (deferred). |

## 9. A page handed to another process

| | |
|---|---|
| Channel | Link preview (Quick Look), Services, Share, Look Up, "open in another app", Handoff: another process fetches the address as this Mac. |
| Why reachable here | AppKit and Safari's menus. |
| Proof | CI 382: `PASS … nothing of a page is handed outside the profile (no link preview, no address opened in another app, no sharing service, no password kept in the keychain, copies local)`. **Handoff**: `-[NSUserActivity becomeCurrent]` is a no-op in the process; there is no packet to see (Bluetooth / iCloud). |
| Close / cost | Closed (`HandOffs`); Handoff closed in code, not measurable. |

## 10. Time zone, language and User-Agent of a profile in its own process

| | |
|---|---|
| Channel | Identity: the Mac's own zone in workers, the Mac's own languages at a first launch, Safari's User-Agent instead of the profile's. |
| Why reachable here | The process's TZ and argv languages, WebKit's own processes, Safari's chrome setting the UA. |
| Proof | CI 382: `PASS … the profile's time zone in the page, a dedicated worker and a service worker`, `PASS … a new proxy's first launch: the page is asked for in the proxy's country's language`, `PASS … the start page goes out with the profile's User-Agent`. |
| Close / cost | Closed. |

## The owner's 5 minutes (macOS 27) — run 2026-10-29

**Done, macOS 27.0.1.** Outcome (item 1): `factories patched` (the hypothesis of renamed factories
was wrong), the content web view `reached its initializer` without the profile's store and got it
there, every web view `is up: proxies=1`, none `is NOT on the profile`, both pages answered by the
proxy. Conditions: the vendor's proxy was dead, so the run used `scripts/selftest_proxy.py --http
18080` with the profile on HTTP CONNECT `127.0.0.1:18080`; a remote proxy over the internet was not
measured. The scenario, kept for the next macOS:

`PB_CHROME_NETS=0` is no longer in the code (removed in 50580f4): a run with it could load pages
as this Mac, a switch that weakens fail-closed in the shipped app. The same question is answered
with the locks in place: Safari's factories either matched (`factories patched: …`) or not (`None
of … factories`), and each web view they missed is logged as caught by the initializer hook.

```sh
cd ~/antifdete7329900 && git pull && SANDBOX=0 scripts/build-app.sh
log stream --level info --predicate 'subsystem == "PrivacyBrowser"' > ~/pb-27.log &
PB_PROFILE_PROCESS=1 build/PrivacyBrowser.app/Contents/MacOS/PrivacyBrowser
# Unlock, start the profile with the German proxy, open https://api.ipify.org in it, note the
# address, quit the app. Then:
kill %1
curl -s https://api.ipify.org; echo
grep -E "chrome is hosted|factories patched|factories is in this Safari|reached its initializer|is up: proxies=|is NOT on the profile|has a proxy=|kernel closes|could not be closed" ~/pb-27.log
```

Closed: `Safari's chrome is hosted in this process`, `has a proxy=true store proxies=1`, every web
view `is up: proxies=1`, no `is NOT on the profile's data`, `The kernel closes to this process:
safari-places, udp`, and the address on the page is the proxy's, not the one `curl` printed.
`None of … factories is in this Safari` would mean Safari renamed them; on macOS 27 they matched
(`factories patched`) and `reached its initializer …` still appeared: the content web view is built
without them, and the hook is what closes it. Anything else: send the output.

## Deferred

One line each; back to them once the list above is closed.

- Main-process profiles (sandboxed build) have no process-wide net — not the Safari-chrome path.
- Profiles in their own processes stop each other's packet tunnel — WebRTC relay; such profiles stay in the main process.
- `leak_check.py` covers our own windows only, not Safari's chrome or WebTransport — test gap.
- `leak_check.py`: "relay candidates … NOT at the proxy address" flips between runs with no relay change (at: 378–380, 383; not: 382, 384, 385) — candidates are relay-only and the data channel goes through the proxy each time; suspected IPv4 vs IPv6 of the trace it compares with — not verified.
- A remote HTTPS site's service worker fetching this Mac — not provable now: the test proxy serves no trusted HTTPS origin.
- Private-network addresses — 10.255.255.1 measured through the proxy (CI 383) and checked; 192.168/16 and 172.16/12 not probed.
- Foundation's per-app stores (cookie jar, HSTS, URL cache) shared between profile processes — not provable now; proof: a Set-Cookie on an icon, then a second profile.
- XPC: a deny list rather than an allow list — needs the chrome's service list from CI.
- Search suggestions driven by typing — not provable now: the self-test does not type into Safari's address bar.
- The JS shim and a frame's initial empty document — fingerprint consistency, not IP.
- `.webarchive` opened in the chrome gets a store without the proxy — refuted: `LoadWebArchiveWithEphemeralStorageEnabled` is off with a proxy.
- Attribution (PCM) reports stored before the proxy — removed at launch; no check.
- The warm-up report counted a run's first page's cookies as the profile's own (its starting point was read before the session was set) — fixed with its check (the self-test's per-site report); not a leak.
- The egress capture counted the self-test's own control profile (no proxy) dialing WebTransport to a documentation address in run 384 (timestamps and source ports fall in that step, before the proxied profile's) — the control now only measures, it does not connect.
- A private window of Safari's chrome writes the profile's persistent store — disk.
- Plaintext in backups and Spotlight while running — disk; checked (`home.noindex`, excluded from backups) in the build without the sandbox; in the sandboxed build the mark does not stay on the container's folders (measured, CI 383–384; writing the attribute directly is measured next) — a documented limitation.
- AppKit saved state, `/var/folders`, recent documents, crash reports — disk.
- An ephemeral profile in its own process keeps Safari's state; unlock recovery of a busy home — disk.
- Credentials from Safari's sheets to the keychain — clamped to the session; disk.
- Spotlight, Screen Time, Biome donations — refused at XPC; disk.
- Log lines in clear — closed (cc9c8f8, `scripts/check_log_privacy.py`).
- The child process given the vault master key — closed (6297e12, `ProfileGrant`).
- The child inheriting the manager's environment; HOME/TMPDIR outside the home — closed (cc9c8f8).
- `PBTunnelAllInterfaces` from arguments; `--check-safari-chrome` unguarded; `--safari-chrome` in release — closed (cc9c8f8, 93e5548).
