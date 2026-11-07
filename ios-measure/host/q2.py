"""Question 2 — a fingerprint adjusted from page scripts, and whether a page can tell (harness.py --scenario q2).

Sessions, each on its own data store, no proxy, the page on this Mac (http://127.0.0.1, a secure context):
  N  — nothing injected: the baseline.
  K  — the naive script (fp_naive.js): plain replacements. The natives check must catch it (red).
  M  — PrivacyScripts' own shim (time zone; its toString registry, frames, blob workers) with the
       fingerprint fixture appended (fp_patch.js): canvas and audio noise, WebGL vendor/renderer,
       hardwareConcurrency. Seed "s1".
  M2 — the same with seed "s2", on another store.
Then M again: after a reload, and in a new web view on the same store.
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

MARK_RENDERER = "Apple GPU (lumen q2)"   # a marker, so the check sees the override took
MARK_CORES = 2                           # likewise: no iPhone or simulator reports 2


def shim_body():
    swift = open(os.path.join(ROOT, "Sources/PrivacyBrowser/Browser/PrivacyScripts.swift"), encoding="utf-8").read()
    return swift.split('static let shimBody = #"""')[1].split('"""#')[0]


def masked_source(seed):
    body = shim_body()
    hook = "  if (CONFIG.storageQuota) {"
    assert hook in body, "PrivacyScripts' patchWindow changed: the fixture cannot hook in"
    body = body.replace(hook, "  try { patchFingerprint(w, CONFIG.fingerprint); } catch (e) {}\n" + hook, 1)
    body += open(os.path.join(HERE, "fp_patch.js"), encoding="utf-8").read()
    config = {"timeZone": "Europe/Berlin", "geolocation": {"mode": "deny"}, "webRTC": "unrestricted", "safariObject": False,
              "storageQuota": None,
              "fingerprint": {"seed": seed, "canvas": "noise", "audio": "noise", "cores": MARK_CORES,
                              "webgl": {"vendor": "Apple Inc.", "renderer": MARK_RENDERER}}}
    # The same wrapping as PrivacyScripts.source(for:): the function must be named `install`.
    return "(function install(CONFIG) {\n" + body + "\n})(" + json.dumps(config) + ");"


def naive_source(seed):
    fp = {"seed": seed, "cores": MARK_CORES, "webgl": {"vendor": "Apple Inc.", "renderer": MARK_RENDERER}}
    return open(os.path.join(HERE, "fp_naive.js"), encoding="utf-8").read().replace("__FP__", json.dumps(fp))


def probe_lies():
    text = open(os.path.join(ROOT, "scripts/test-shims.mjs"), encoding="utf-8").read()
    raw = text.split("const probeLies = `", 1)[1].split("`;", 1)[0]
    return raw.replace("\\\\", "\\")   # one level of the template literal's escapes


def probe(label):
    cfg = {"label": label, "probeLies": probe_lies()}
    return open(os.path.join(HERE, "q2_probe.js"), encoding="utf-8").read().replace("__CFG__", json.dumps(cfg))


async def scenario(h, capture):
    app, check = h.APP, h.check
    page = f"http://127.0.0.1:{h.ARGS.http_port}/blank?q2=1"
    scripts = {
        "N": [],
        "K": [{"source": naive_source("s1"), "mainFrameOnly": False}],
        "M": [{"source": masked_source("s1"), "mainFrameOnly": False}],
        "M2": [{"source": masked_source("s2"), "mainFrameOnly": False}],
    }
    stores = {k: f"persistent:{__import__('uuid').uuid4()}" for k in scripts}
    results = {}
    for sid, user_scripts in scripts.items():
        await app.cmd("session", session=sid, store=stores[sid], userScripts=user_scripts)
        loaded = await app.cmd("load", session=sid, url=page + f"&sid={sid}", timeout=30)
        result = await app.cmd("eval", session=sid, js=probe(sid), timeout=90)
        results[sid] = result.get("value") if isinstance(result.get("value"), dict) else {"error": result}
        print(f"probe {sid}: load ok={loaded.get('ok')}", json.dumps(results[sid])[:3000], flush=True)
    # M after a reload, and in a new web view on the same store.
    await app.cmd("load", session="M", url=page + "&sid=M&again=1", timeout=30)
    again = (await app.cmd("eval", session="M", js=probe("M-reload"), timeout=90)).get("value") or {}
    await app.cmd("session", session="M", store=stores["M"], userScripts=scripts["M"])
    await app.cmd("load", session="M", url=page + "&sid=M&view=2", timeout=30)
    newview = (await app.cmd("eval", session="M", js=probe("M-newview"), timeout=90)).get("value") or {}

    try:
        await language(h)
    except Exception as error:
        check("q2.language-at-runtime", "INCONCLUSIVE", f"stopped: {error!r}")
    # The reference was taken over plain http on a LAN address, which is not a secure context; a
    # page on 127.0.0.1 is one. So the web view is read again where it is not: http through a proxy.
    insecure = {}
    try:
        proxy = {"type": "http", "host": h.ARGS.proxy_host, "port": h.ARGS.port_a, "user": "ua", "pass": "pa"}
        await app.cmd("session", session="NI", store="ephemeral", proxies=[proxy])
        await app.cmd("load", session="NI", url=f"http://ni-{h.ARGS.run}.lumentest:{h.ARGS.http_port}/blank", timeout=30)
        insecure = (await app.cmd("eval", session="NI", js="return { secure: isSecureContext, names: Object.getOwnPropertyNames(window), ua: navigator.userAgent };")).get("value") or {}
    except Exception as error:
        insecure = {"error": repr(error)}
    N, K, M, M2 = (results[k] for k in ("N", "K", "M", "M2"))
    with open(os.path.join(h.ARGS.out, "q2-probes.json"), "w") as f:
        json.dump({"N": N, "K": K, "M": M, "M2": M2, "M-reload": again, "M-newview": newview, "N-insecure": insecure}, f, indent=1)

    def g(d, *path):
        for p in path:
            d = d.get(p) if isinstance(d, dict) else None
        return d

    # --- the baseline itself
    check("q2.baseline", "INFO",
          f"N: UA {g(N, 'navigator', 'userAgent')}; platform {g(N, 'navigator', 'platform')}, cores {g(N, 'navigator', 'cores')}, "
          f"touch {g(N, 'navigator', 'maxTouchPoints')}, language {g(N, 'navigator', 'language')} {g(N, 'navigator', 'languages')}, "
          f"screen {g(N, 'screen')}, WebGL {g(N, 'webgl', 'unmaskedVendor')} / {g(N, 'webgl', 'unmaskedRenderer')}, "
          f"window.safari {g(N, 'windowSafari')}, window own properties {g(N, 'windowOwn')} (owner's iPhone, Safari 27: 951), "
          f"time zone {g(N, 'timeZone')}, standalone {g(N, 'navigator', 'standalone')}")
    stable_n = len(set(N.get("canvasReads") or [None])) == 1
    check("q2.baseline-canvas-stable", "PASS" if stable_n else "FAIL",
          f"N: 5 reads of one canvas {N.get('canvasReads')} — the engine itself adds no noise to a read", core=True)
    check("q2.baseline-first-draw", "INFO",
          f"N: the first canvas drawn after the app started {N.get('canvas')}, the same drawing again {N.get('canvasFresh')} "
          f"(differs when fonts, emoji included, were still loading at the first draw)")
    ref = {}
    try:
        ref = json.load(open(os.path.join(HERE, "iphone_reference.json")))
    except OSError:
        pass

    # --- the spoof takes
    check("q2.M.canvas-changed", "PASS" if M.get("canvas") and M.get("canvas") != N.get("canvas") else "FAIL",
          f"N {N.get('canvas')} → M {M.get('canvas')} (partly transparent pixels in the drawing: {M.get('partialAlphaPixels')})", core=True)
    check("q2.M.canvas-per-seed", "PASS" if M.get("canvas") != M2.get("canvas") else "FAIL",
          f"seed s1 {M.get('canvas')}, seed s2 {M2.get('canvas')}", core=True)
    check("q2.M.webgl", "PASS" if g(M, "webgl", "unmaskedRenderer") == MARK_RENDERER else "FAIL",
          f"UNMASKED_RENDERER {g(N, 'webgl', 'unmaskedRenderer')} → {g(M, 'webgl', 'unmaskedRenderer')}", core=True)
    check("q2.M.audio", "PASS" if g(M, "audio", "sum") and g(M, "audio", "sum") != g(N, "audio", "sum") else "FAIL",
          f"sum {g(N, 'audio', 'sum')} → {g(M, 'audio', 'sum')}; getChannelData and copyFromChannel agree: {g(M, 'audio', 'consistent')}", core=True)
    check("q2.M.cores", "PASS" if g(M, "navigator", "cores") == MARK_CORES else "FAIL",
          f"hardwareConcurrency {g(N, 'navigator', 'cores')} → {g(M, 'navigator', 'cores')}", core=True)
    check("q2.M.timezone", "PASS" if g(M, "timeZone", "intl") == "Europe/Berlin" else "FAIL",
          f"{g(N, 'timeZone')} → {g(M, 'timeZone')}", core=True)

    # --- stability of the noise
    reads = M.get("canvasReads") or []
    check("q2.M.stable-within-page", "PASS" if reads and len(set(reads)) == 1 and M.get("canvasFresh") == M.get("canvas")
          and len(set(M.get("imageDataReads") or [None])) == 1 else "FAIL",
          f"5 toDataURL reads {sorted(set(reads))}, a fresh canvas {M.get('canvasFresh')}, 3 getImageData reads {sorted(set(M.get('imageDataReads') or []))}",
          core=True)
    check("q2.M.stable-reload", "PASS" if again.get("canvas") == M.get("canvas") and g(again, "audio", "sum") == g(M, "audio", "sum") else "FAIL",
          f"after reload: canvas {again.get('canvas')} audio {g(again, 'audio', 'sum')}", core=True)
    check("q2.M.stable-new-view", "PASS" if newview.get("canvas") == M.get("canvas") and g(newview, "audio", "sum") == g(M, "audio", "sum") else "FAIL",
          f"new web view, same store: canvas {newview.get('canvas')} audio {g(newview, 'audio', 'sum')}", core=True)

    # --- the natives check: red on K, then M
    def lies_of(d, scope):
        return {k: v.get(scope) for k, v in (d.get("lies") or {}).items() if v.get(scope)}
    patched = ["HTMLCanvasElement.prototype.toDataURL", "CanvasRenderingContext2D.prototype.getImageData",
               "WebGLRenderingContext.prototype.getParameter", "AudioBuffer.prototype.getChannelData",
               'Object.getOwnPropertyDescriptor(Navigator.prototype, "hardwareConcurrency").get']
    k_lies = lies_of(K, "top")
    caught = [p for p in patched if p in k_lies]
    check("q2.natives.red-naive-caught", "PASS" if len(caught) == len(patched) else "FAIL",
          f"the naive script: {len(caught)}/{len(patched)} replacements caught; e.g. {list(k_lies.items())[:2]}", core=True)
    n_lies = lies_of(N, "top")
    check("q2.natives.baseline-clean", "PASS" if not n_lies else "FAIL",
          f"nothing injected, the check finds: {n_lies or 'nothing'} (a check that flags the real engine is useless)", core=True)
    m_top, m_frame = lies_of(M, "top"), lies_of(M, "frame")
    check("q2.natives.M-top", "PASS" if not m_top else "FAIL",
          f"the masked script, this window's toString: {m_top or 'no lie found'}", core=True)
    check("q2.natives.M-blank-frame-toString", "PASS" if not m_frame else "FAIL",
          f"through an about:blank frame's own Function.prototype.toString: {m_frame or 'no lie found'}", core=True)

    # --- other ways a page can tell
    fb = M.get("frameBlank") or {}
    check("q2.M.blank-frame-apis", "PASS" if fb.get("canvas") == M.get("canvas") and fb.get("cores") == MARK_CORES
          and fb.get("timeZone") == "Europe/Berlin" else "FAIL",
          f"an about:blank frame's own toDataURL on the page's canvas {fb.get('canvas')} (page {M.get('canvas')}), its cores "
          f"{fb.get('cores')}, its zone {fb.get('timeZone')}, its toString of its toDataURL {fb.get('toDataURLText')!r}", core=True)
    fs = M.get("frameSameOrigin") or {}
    check("q2.M.same-origin-frame", "PASS" if fs.get("canvas") == M.get("canvas") and fs.get("cores") == MARK_CORES else "FAIL",
          f"a same-origin frame: {fs}", core=True)
    for kind in ("workerBlob", "workerURL"):
        wk, wn = M.get(kind) or {}, N.get(kind) or {}
        same_cores = wk.get("cores") == MARK_CORES
        same_zone = wk.get("timeZone") == "Europe/Berlin"
        offscreen_noised = wk.get("offscreen") != wn.get("offscreen")
        status = "PASS" if same_cores and same_zone and offscreen_noised else "LEAK"
        check(f"q2.M.{kind}", status,
              f"cores {wk.get('cores')} (page {MARK_CORES}), zone {wk.get('timeZone')}, OffscreenCanvas {wk.get('offscreen')} "
              f"(unpatched N: {wn.get('offscreen')}) — a worker that disagrees with its page gives the spoof away")
    check("q2.M.solid-fill", "PASS" if M.get("solidFillChanged") == 0 else "FAIL",
          f"pixels of a solid rectangle changed by the noise: {M.get('solidFillChanged')}", core=True)
    check("q2.M.known-pixels", "PASS" if M.get("knownPixelsChanged") == 0 else "FAIL",
          f"bytes of an opaque pattern put and read back that differ: {M.get('knownPixelsChanged')}", core=True)
    check("q2.M.dataURL-vs-imageData", "PASS" if M.get("dataURLvsImageData") == 0 else "FAIL",
          f"bytes that differ between getImageData and the PNG drawn back: {M.get('dataURLvsImageData')} (N: {N.get('dataURLvsImageData')})",
          core=True)

    def norm_stack(e):
        if not isinstance(e, dict):
            return e
        return {"name": e.get("name"), "message": e.get("message"),
                "stack": [re.sub(r":\d+:\d+", "", s) for s in (e.get("stack") or [])]}
    diffs = {}
    for key in (N.get("errors") or {}):
        a, b = norm_stack(N["errors"][key]), norm_stack((M.get("errors") or {}).get(key))
        if a != b:
            diffs[key] = {"N": a, "M": b}
    check("q2.M.errors-and-stacks", "PASS" if not diffs else "FAIL",
          f"wrong calls: message and stack frames differ from the engine's in {sorted(diffs) or 'none'}; " + json.dumps(diffs)[:1200],
          core=True)
    shapes = {k: (N.get("protoShapes") or {}).get(k) == v for k, v in (M.get("protoShapes") or {}).items()}
    extra = sorted(set(M.get("windowNames") or []) - set(N.get("windowNames") or []))
    missing = sorted(set(N.get("windowNames") or []) - set(M.get("windowNames") or []))
    check("q2.M.shapes", "PASS" if all(shapes.values()) and not extra and not missing and M.get("navigatorOwn") == N.get("navigatorOwn") else "FAIL",
          f"prototype property lists equal to the engine's: {shapes}; window own properties N {N.get('windowOwn')} M {M.get('windowOwn')}, "
          f"extra {extra[:10]}, missing {missing[:10]}", core=True)
    if ref.get("windowNames"):
        safari = set(ref["windowNames"]) - set(ref.get("pageGlobals") or [])
        for label, names, secure in (("insecure", insecure.get("names"), insecure.get("secure")),
                                     ("secure", N.get("windowNames"), True)):
            if not names:
                check(f"q2.webview-vs-safari-{label}", "INCONCLUSIVE", f"no names read ({insecure.get('error') if label == 'insecure' else ''})")
                continue
            view = set(names)
            only_safari, only_view = sorted(safari - view), sorted(view - safari)
            check(f"q2.webview-vs-safari-{label}", "INFO" if label == "secure" else ("PASS" if not only_safari and not only_view else "FAIL"),
                  f"this web view ({app.info.get('os')}, isSecureContext {secure}): {len(view)} own window properties; Safari on the "
                  f"owner's iPhone ({ref.get('context')}): {len(safari)} without the probe page's own {ref.get('pageGlobals')}; "
                  f"only in Safari {len(only_safari)} {only_safari}; only in the web view {len(only_view)} {only_view[:60]}")
    else:
        check("q2.webview-vs-safari", "INFO",
              f"this web view has {N.get('windowOwn')} own window properties; the owner's iPhone Safari 27 has 951 (no reference list)")



async def language(h):
    """Language per session: WKWebView has no public setting for it. Does changing the app's
    AppleLanguages at run time reach a web view made afterwards (header and navigator)?"""
    app, check = h.APP, h.check
    page = f"http://127.0.0.1:{h.ARGS.http_port}/whoami?q2=lang"
    js = "return { language: navigator.language, languages: Array.from(navigator.languages), header: (await (await fetch('/whoami?k=lang')).json()) };"
    await app.cmd("session", session="L1", store="ephemeral")
    await app.cmd("load", session="L1", url=page + "&s=L1", timeout=30)
    before = (await app.cmd("eval", session="L1", js=js)).get("value") or {}
    header_before = [e.get("lang") for e in h.EVENTS if e["kind"] == "site" and (e.get("query") or {}).get("s") == "L1"]
    changed = await app.cmd("defaults", key="AppleLanguages", value=["de-DE"])
    await app.cmd("session", session="L2", store="ephemeral")
    await app.cmd("load", session="L2", url=page + "&s=L2", timeout=30)
    after = (await app.cmd("eval", session="L2", js=js)).get("value") or {}
    header_after = [e.get("lang") for e in h.EVENTS if e["kind"] == "site" and (e.get("query") or {}).get("s") == "L2"]
    await app.cmd("defaults", key="AppleLanguages", value=None)
    took = after.get("language", "").lower().startswith("de") and any((x or "").lower().startswith("de") for x in header_after)
    check("q2.language-at-runtime", "INFO",
          f"before: navigator {before.get('language')} {before.get('languages')}, Accept-Language {header_before}; AppleLanguages set to de-DE "
          f"({changed.get('preferredLanguages')}); a new web view: navigator {after.get('language')} {after.get('languages')}, "
          f"Accept-Language {header_after} — {'follows without a relaunch' if took else 'does not follow without a relaunch'}")
