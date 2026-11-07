"""Question 3 — Telegram in a session of its own, through that session's proxy (harness.py --scenario q3).

No Telegram account is used: what needs one is in DEVICE.md for the owner.
  1. Telegram Web (K and A) in sessions behind proxy A (HTTP) and proxy B (SOCKS5), reaching the
     internet through them: does it load, does it reach the QR sign-in (its MTProto connection is
     up: the QR code is a login token from Telegram's servers), which hosts did it use, did any
     name get asked of this Mac's resolver by WebKit rather than by the proxy, service workers.
  2. A mini app hosted by the session itself, with the iOS client's bridge (TelegramWebviewProxy)
     emulated: does Telegram's own SDK (telegram.org/js/telegram-web-app.js) take it as iOS, and do
     its events reach the host app both ways.
  3. App-Bound Domains (the "bound" build): service workers for web.telegram.org, and what that
     costs elsewhere (scripts on other sites).
"""
import json
import re
import time
import urllib.parse
import uuid

BRIDGE = r"""
// The iOS Telegram client's bridge, as the SDK looks for it: window.TelegramWebviewProxy.postEvent.
window.TelegramWebviewProxy = { postEvent(type, data) { (window.__lumenTgEvents = window.__lumenTgEvents || []).push([type, data]); } };
"""

TG_HOST = re.compile(r"telegram|t\.me\b|tdesktop|telesco", re.I)
TG_SOCKET = re.compile(r"^[kz]ws\d")   # Telegram Web's MTProto-over-WebSocket hosts (kws1…, zws2…)


def init_data(run):
    user = {"id": 7000000001, "first_name": "Lumen", "last_name": "Probe", "username": "lumen_probe", "language_code": "en"}
    fields = {"query_id": f"AAH{run}", "user": json.dumps(user, separators=(",", ":")), "auth_date": str(int(time.time())),
              "hash": "0" * 64}   # not signed: only Telegram (with the bot's token) can sign it
    return urllib.parse.urlencode(fields)


async def telegram_web(h, sid, url, wait):
    app, check = h.APP, h.check
    started = time.time()
    loaded = await app.cmd("load", session=sid, url=url, timeout=60)
    state = {}
    for _ in range(int(wait / 5)):
        await app.cmd("sleep", seconds=5)
        r = await app.cmd("eval", session=sid, timeout=30, js="""
            const canvases = Array.from(document.querySelectorAll('canvas')).map((c) => [c.width, c.height, c.className || c.parentElement && c.parentElement.className]);
            const text = (document.body && document.body.innerText || '').slice(0, 300);
            let regs = null; try { regs = navigator.serviceWorker ? (await navigator.serviceWorker.getRegistrations()).map((r) => r.scope) : 'no navigator.serviceWorker'; } catch (e) { regs = 'error ' + e.message; }
            return { title: document.title, url: location.href, canvases, text, serviceWorker: typeof navigator.serviceWorker, registrations: regs,
                     sharedWorker: typeof SharedWorker, controller: !!(navigator.serviceWorker && navigator.serviceWorker.controller),
                     localStorageKeys: Object.keys(localStorage).slice(0, 20),
                     signIn: /phone number|Sign in|Log in/i.test(text),
                     qr: !!document.querySelector('.qr-container canvas, .auth-image canvas, [class*="qr"] canvas, canvas[class*="qr"], [class*="qr"] svg') };""")
        state = r.get("value") if isinstance(r.get("value"), dict) else {"error": r}
        if state.get("signIn") or state.get("qr"):
            break
    hosts = sorted({(e["proxy"], e.get("host"), e.get("port"), e.get("method")) for e in h.EVENTS
                    if e["kind"] == "proxy" and e.get("t", 0) >= started and e["proxy"] == ("A" if sid == "T1" else "B")})
    return loaded, state, hosts, started


async def scenario(h, capture):
    app, check, args = h.APP, h.check, h.ARGS
    info = app.info
    bound = bool(info.get("appBoundDomains"))
    check("q3.build", "INFO", f"{info.get('os')}, bundle {info.get('bundle')}, WKAppBoundDomains {info.get('appBoundDomains')}")
    proxy_a = {"type": "http", "host": args.proxy_host, "port": args.port_a, "user": "ua", "pass": "pa", "allowFailover": False}
    proxy_b = {"type": "socks5", "host": args.proxy_host, "port": args.port_b, "user": "ub", "pass": "pb", "allowFailover": False}
    extra = {"limitsNavigationsToAppBoundDomains": True} if bound else {}
    await app.cmd("session", session="T1", store=f"persistent:{uuid.uuid4()}", proxies=[proxy_a], **extra)
    await app.cmd("session", session="T2", store=f"persistent:{uuid.uuid4()}", proxies=[proxy_b], **extra)

    # Red first: behind a dead proxy (fail-closed), Telegram Web must not load at all.
    await app.cmd("session", session="T0", store=f"persistent:{uuid.uuid4()}",
                  proxies=[{"type": "http", "host": args.proxy_host, "port": args.port_dead, "allowFailover": False}], **extra)
    loaded, state, _, _ = await telegram_web(h, "T0", "https://web.telegram.org/k/", 10)
    check("q3.red-dead-proxy", "PASS" if not (state.get("signIn") or state.get("qr")) else "FAIL",
          f"the same check behind a dead proxy: load ok={loaded.get('ok')} ({loaded.get('error')}), QR shown: {state.get('qr')} "
          f"— the QR check fails when Telegram is not reached", core=True)

    for sid, url in (("T1", "https://web.telegram.org/k/"), ("T2", "https://web.telegram.org/a/")):
        loaded, state, hosts, started = await telegram_web(h, sid, url, 60)
        own = "A" if sid == "T1" else "B"
        tg_hosts = sorted({x[1] for x in hosts if x[1] and TG_HOST.search(x[1])})
        sockets = sorted({h for h in tg_hosts if TG_SOCKET.match(h)})
        keys = [k for k in (state.get("localStorageKeys") or []) if "auth_key" in k]
        check(f"q3.{sid}.telegram-web", "PASS" if loaded.get("ok") and (state.get("signIn") or state.get("qr")) and sockets else "FAIL",
              f"{url} through proxy {own}: load ok={loaded.get('ok')} ({loaded.get('error')}); title {state.get('title')!r}; "
              f"sign-in screen: {state.get('signIn')}, QR: {state.get('qr')}; MTProto WebSocket hosts reached through the proxy: {sockets}; "
              f"auth keys in localStorage: {keys}; text {state.get('text', '')[:100]!r}", core=True)
        check(f"q3.{sid}.hosts", "INFO", f"hosts the session reached through proxy {own}: {tg_hosts} (all: {len(hosts)} connections)")
        check(f"q3.{sid}.workers", "INFO",
              f"navigator.serviceWorker {state.get('serviceWorker')}, registrations {state.get('registrations')}, controller "
              f"{state.get('controller')}, SharedWorker {state.get('sharedWorker')}, localStorage keys {state.get('localStorageKeys')}")
        # Names WebKit asked of this Mac's resolver itself (not the proxy on its behalf).
        if capture.state.startswith("running"):
            lines = [l for l in capture.lines() if TG_HOST.search(l)]
            by_webkit = [l for l in lines if "python" not in l.lower()]
            check(f"q3.{sid}.dns", "LEAK" if by_webkit else "PASS",
                  f"Telegram names in the DNS capture: {len(lines)} lines; not asked for the proxy (python): {by_webkit[:3]}")

    # A mini app with the iOS bridge emulated, its SDK from telegram.org through the proxy.
    run = args.run
    theme = json.dumps({"bg_color": "#ffffff", "text_color": "#000000", "button_color": "#2481cc", "button_text_color": "#ffffff"})
    fragment = urllib.parse.urlencode({"tgWebAppData": init_data(run), "tgWebAppVersion": "9.1", "tgWebAppPlatform": "ios",
                                       "tgWebAppThemeParams": theme})
    mini = f"https://app-{run}.lumentest:{args.https_port}/static/miniapp.html#{fragment}"
    await app.cmd("session", session="T3", store=f"persistent:{uuid.uuid4()}", proxies=[proxy_a],
                  userScripts=[{"source": BRIDGE, "mainFrameOnly": True}])
    loaded = await app.cmd("load", session="T3", url=mini, timeout=60)
    await app.cmd("sleep", seconds=3)
    r = await app.cmd("eval", session="T3", js="""
        const W = window.Telegram && window.Telegram.WebApp;
        if (!W) return { sdk: false };
        W.ready(); W.expand();
        window.Telegram.WebView.receiveEvent('viewport_changed', { height: 701, is_expanded: true, is_state_stable: true });
        W.MainButton.setText('Lumen'); W.MainButton.show();
        await new Promise((r) => setTimeout(r, 500));
        return { sdk: true, platform: W.platform, version: W.version, user: W.initDataUnsafe && W.initDataUnsafe.user,
                 initDataLength: (W.initData || '').length, viewportHeight: W.viewportHeight, isExpanded: W.isExpanded,
                 events: (window.__lumenTgEvents || []).map((e) => e[0]) };""")
    v = r.get("value") if isinstance(r.get("value"), dict) else {"error": r}
    events = v.get("events") or []
    ok = v.get("sdk") and v.get("platform") == "ios" and "web_app_ready" in events and "web_app_expand" in events and v.get("viewportHeight") == 701
    sdk_via = sorted({e.get("host") for e in h.EVENTS if e["kind"] == "proxy" and e["proxy"] == "A" and "telegram.org" == e.get("host")})
    check("q3.miniapp-bridge", "PASS" if ok else "FAIL",
          f"load ok={loaded.get('ok')} ({loaded.get('error')}); SDK through proxy A from {sdk_via}; WebApp.platform {v.get('platform')!r}, "
          f"version {v.get('version')}, user {v.get('user')}, events the host app received {events}, viewport after the host's event "
          f"{v.get('viewportHeight')} (initData here is unsigned: a bot's server would refuse it); eval error: {r.get('error')}", core=True)

    # Red: the same mini app without the bridge — the SDK must not say iOS.
    await app.cmd("session", session="T3r", store=f"persistent:{uuid.uuid4()}", proxies=[proxy_a])
    await app.cmd("load", session="T3r", url=mini.replace("tgWebAppPlatform=ios", "tgWebAppPlatform=unknown"), timeout=60)
    await app.cmd("sleep", seconds=3)
    r = await app.cmd("eval", session="T3r", js="const W = window.Telegram && window.Telegram.WebApp; return W ? { platform: W.platform, bridge: typeof window.TelegramWebviewProxy } : { sdk: false };")
    rv = r.get("value") or {}
    check("q3.red-no-bridge", "PASS" if rv.get("platform") != "ios" and rv.get("bridge") == "undefined" else "FAIL",
          f"without the bridge and the iOS parameter: platform {rv.get('platform')!r}, bridge {rv.get('bridge')} — the bridge check can fail", core=True)

    # t.me: what a link to a bot or mini app gives in a browser.
    await app.cmd("session", session="T4", store=f"persistent:{uuid.uuid4()}", proxies=[proxy_a])
    loaded = await app.cmd("load", session="T4", url="https://t.me/durov", timeout=40)
    r = await app.cmd("eval", session="T4", js="""return Array.from(document.querySelectorAll('a')).map((a) => a.href).filter((h) => /^tg:|web\\.telegram|telegram\\.org\\/dl/.test(h)).slice(0, 8);""")
    check("q3.tme-link", "INFO", f"t.me page in a session: load ok={loaded.get('ok')}; its links out: {r.get('value')}")

    # App-Bound Domains: what a script can do on a site that is not bound (bound build only).
    if bound:
        for label, url in (("loopback", f"http://127.0.0.1:{args.http_port}/blank?bound=1"), ("t.me", "https://t.me/durov"),
                           ("web.telegram.org", "https://web.telegram.org/k/")):
            sid = "T5" + label.replace(".", "")
            await app.cmd("session", session=sid, store=f"persistent:{uuid.uuid4()}", proxies=[proxy_a],
                          userScripts=[{"source": "window.__lumenUserScript = 1;", "mainFrameOnly": True}])
            lr = await app.cmd("load", session=sid, url=url, timeout=40)
            r = await app.cmd("eval", session=sid, js="return { userScript: typeof window.__lumenUserScript, href: location.href };")
            check(f"q3.bound-scripts-{label}", "INFO",
                  f"bound build, {url} (load ok={lr.get('ok')}): user script ran: {(r.get('value') or {}).get('userScript')}; "
                  f"callAsyncJavaScript ok={r.get('ok')} error={r.get('error')}")
