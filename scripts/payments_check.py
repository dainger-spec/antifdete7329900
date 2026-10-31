#!/usr/bin/env python3
"""Apple Pay, Payment Request and Web Push: what their calls answer in this Mac's Safari and in a
profile. A measurement for the parity rule (docs/ISOLATION_AND_LIMITATIONS.md §2, *Parity with
Safari*); it turns nothing on in the app.

    python3 scripts/payments_check.py --app build/unsandboxed/PrivacyBrowser.app --trust system --out build/payments

One page, served here over HTTPS, measures itself: which of the interfaces the window has, the
window's own property names, and what each call answers — `ApplePaySession.canMakePayments()`,
`supportsVersion(3)`, `canMakePaymentsWithActiveCard()`, a session made without a user gesture,
`PaymentRequest(…).canMakePayment()`, `Notification.permission`, the permission queries, and a
service worker's `pushManager`: `permissionState()`, `getSubscription()`, `subscribe()` without a
user gesture; `window.pushManager` too. Nothing is evaluated into the page from outside: a script
an app or WebDriver runs in a page is part of what is measured here, so the page's own script is
the only one. Apple Pay answers only a page with a certificate, hence HTTPS.

The page is opened in this Mac's Safari, and in new profiles of the app (`PrivacyBrowser
--payments-check`, PaymentsCheck.swift), one variant at a time:

  shipped                the profile as it ships, in the app's own window
  shipped-safari-window  the profile as it ships, in Safari's window (the build without the App Sandbox)
  on-page                WebKit's own switches for them on (ApplePayEnabled, PushAPIEnabled), the profile's
                         scripts as they ship: its privacy script in the page's world
  on-isolated            the same switches, the privacy script in a world of its own
  on-none                the same switches, no script at all

Each profile has an HTTP proxy at 127.0.0.1:9 (--proxy; nothing answers there, and the page, on
this Mac, loads directly), as a customer's profile has a proxy.

The certificate: a throwaway authority made here, valid for a day, whose private key is deleted
as soon as it has signed the page's certificate (for 127.0.0.1 and localhost): nothing else can
ever be signed with it. With --trust it is trusted for the run and removed again at the end — in
the System keychain with sudo (`system`, as CI does), or in the user's login keychain (`user`:
macOS asks for the password or Touch ID); without it, the Mac must already trust it, or neither
browser loads the page.

Prints a PAYMENTS line per call and side; then, per side, a PAYMENTS-SUMMARY line, a
PAYMENTS-CALLS line (Safari's every answer, a variant's where Safari answers otherwise) and a
PAYMENTS-NAMES line (the window's own property names only one side has); and writes every report
to --out/payments.json. Exit 0 when Safari and every variant reported, 2 when Safari did not
(nothing to compare with), 1 when a variant did not; 3 when every side reported but the throwaway
authority could not be removed again (a line says so, and what to remove by hand).
"""

import argparse
import base64
import json
import os
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CA_NAME = "PrivacyBrowser payments check CA (throwaway)"
# Measurement round 2: the page under a name (Web Authentication refuses a page on an address), which
# CI maps to 127.0.0.1 in /etc/hosts; the certificate names it too.
PAGE_HOST = os.environ.get("PB_PAGE_HOST", "127.0.0.1")
VARIANTS = ["shipped", "shipped-safari-window", "on-page", "on-isolated", "on-none", "parity"]

INTERFACES = [
    "ApplePaySession", "ApplePaySetup", "ApplePaySetupFeature", "ApplePayError", "MerchantValidationEvent",
    "PaymentRequest", "PaymentResponse", "PaymentAddress", "PaymentMethodChangeEvent",
    "PaymentRequestUpdateEvent", "PushManager", "PushSubscription", "PushSubscriptionOptions",
    "Notification", "ServiceWorkerRegistration", "safari", "RTCPeerConnection", "PublicKeyCredential",
    "WebTransport", "DigitalCredential", "MediaSessionCoordinator", "CredentialsContainer",
]

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>Apple Pay and Web Push</title></head>
<body><p id="state">Measuring…</p>
<button id="gesture" style="position:fixed;left:0;top:0;width:100%;height:100%;opacity:0.01">Go</button>
<script>
(async function () {
  const INTERFACES = __INTERFACES__;
  const KEY = __KEY__;
  const side = new URLSearchParams(location.search).get('side') || '?';
  const report = { side: side, userAgent: navigator.userAgent, secureContext: window.isSecureContext };
  const names = Object.getOwnPropertyNames(window);
  report.windowOwnCount = names.length;
  report.windowOwnNames = names.slice().sort();
  report.present = {};
  for (const name of INTERFACES) report.present[name] = typeof window[name];
  report.present['navigator.pushManager'] = 'pushManager' in navigator ? typeof navigator.pushManager : 'absent';
  report.present['window.pushManager'] = 'pushManager' in window ? typeof window.pushManager : 'absent';
  report.calls = {};
  // Each call has ten seconds: one that never answers is an answer too, and must not keep the
  // others from being reported.
  const LATE = {};
  async function call(name, run) {
    let timer;
    const late = new Promise((resolve) => { timer = setTimeout(() => resolve(LATE), 10000); });
    try {
      const value = await Promise.race([Promise.resolve().then(run), late]);
      report.calls[name] = value === LATE ? { ok: false, name: 'no answer', message: 'within 10 s' }
        : { ok: true, value: value === undefined ? 'undefined' : value };
    } catch (error) {
      report.calls[name] = { ok: false, name: String(error && error.name), message: String(error && error.message) };
    } finally {
      clearTimeout(timer);
    }
  }
  // ---- Round 3 (the owner's questions of 1 November): can a Web Authentication ceremony be taken
  // in this app's process before the system shows its sheet; how does this app's refusal differ from
  // a user's cancel in Safari; how long does Safari's sheet take. Each step says when it began and
  // ended to the app (its trace and its interception, through a script message handler only the
  // app's measurement view has) and to the server (Safari's sheet watcher), and records its outcome:
  // the value, or the error's name and message, and the milliseconds it took. (The Apple Pay and Web
  // Push calls of the first rounds are answered, and not asked again.)
  const since = (started) => Math.round(performance.now() - started);
  const describe = (value) => value === undefined ? 'undefined' : value === null ? 'null'
    : (typeof value === 'object' ? ((value.constructor && value.constructor.name) || 'object') + ' ' + JSON.stringify(value) : String(value));
  const mark = (step, phase, extra) => {
    try { window.webkit.messageHandlers.pbmark.postMessage(Object.assign({ step: step, phase: phase }, extra || {})); } catch (e) {}
    return fetch('/mark?side=' + encodeURIComponent(side) + '&step=' + encodeURIComponent(step) + '&phase=' + phase,
      { method: 'POST' }).catch(() => {});
  };
  report.webauthn = {};
  async function measured(step, mode, abortAfter, run) {
    await mark(step, 'begin', { mode: mode });
    const controller = new AbortController();
    const timer = abortAfter ? setTimeout(() => controller.abort(), abortAfter) : null;
    const started = performance.now();
    const at = Date.now();
    let outcome;
    try {
      outcome = { ok: true, value: describe(await run(controller.signal)), ms: since(started), at: at };
    } catch (error) {
      outcome = { ok: false, name: String(error && error.name), message: String(error && error.message), ms: since(started), at: at };
    }
    if (timer) clearTimeout(timer);
    report.webauthn[step] = outcome;
    await mark(step, 'end', { result: JSON.stringify(outcome) });
    return outcome;
  }
  const bytes = (count) => crypto.getRandomValues(new Uint8Array(count));
  const create = (signal) => navigator.credentials.create({ signal: signal, publicKey: { rp: { name: 'Parity check' },
    user: { id: bytes(16), name: 'check', displayName: 'Check' }, challenge: bytes(32),
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } });
  const get = (signal) => navigator.credentials.get({ signal: signal, publicKey: { challenge: bytes(32), rpId: location.hostname } });
  const conditional = (signal) => navigator.credentials.get({ signal: signal, mediation: 'conditional',
    publicKey: { challenge: bytes(32), rpId: location.hostname } });
  await measured('isUserVerifyingPlatformAuthenticatorAvailable', 'pass', 0,
    () => PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
  await measured('isConditionalMediationAvailable', 'pass', 0, () => PublicKeyCredential.isConditionalMediationAvailable());
  await measured('getClientCapabilities', 'pass', 0,
    () => typeof PublicKeyCredential.getClientCapabilities === 'function' ? PublicKeyCredential.getClientCapabilities() : 'absent');
  // Safari: no click (none can be given to it here); every ceremony runs until the sheet watcher's
  // Escape, at most 15 s. The app: each click runs the next step, a user gesture.
  const safariSteps = [
    ['create', 'pass', 15000, create], ['get', 'pass', 15000, get], ['get conditional', 'pass', 6000, conditional],
  ];
  const appSteps = [
    ['create', 'pass', 15000, create], ['create held then cancelled', 'cancel', 15000, create],
    ['get', 'pass', 15000, get], ['get held then cancelled', 'cancel', 15000, get],
    ['get conditional', 'pass', 6000, conditional], ['get conditional held', 'hold', 6000, conditional],
  ];
  const inApp = (() => { try { return !!window.webkit.messageHandlers.pbmark; } catch (e) { return false; } })();
  report.webauthnSide = inApp ? 'the app, each ceremony on a click' : 'without a click';
  if (!inApp) {
    for (const [step, mode, abortAfter, run] of safariSteps) await measured(step, mode, abortAfter, run);
  } else {
    await new Promise((resolve) => {
      let index = 0;
      let busy = false;
      document.getElementById('gesture').addEventListener('click', async () => {
        if (busy || index >= appSteps.length) return;
        busy = true;
        const [step, mode, abortAfter, run] = appSteps[index++];
        await measured(step + ' on a click', mode, abortAfter, run);
        busy = false;
        if (index >= appSteps.length) resolve();
      });
      setTimeout(resolve, 150000);
    });
  }
  await fetch('/report?side=' + encodeURIComponent(side), { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(report) });
  document.getElementById('state').textContent = 'Done. This page can be closed.';
})();
</script></body></html>
"""

SERVICE_WORKER = "self.addEventListener('push', () => {});\n"


def log(message):
    print(message, flush=True)


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def make_certificates(directory):
    """A throwaway authority, and the page's certificate (127.0.0.1, localhost). The authority's
    key is gone before this returns: nothing else can ever be signed with it."""
    ca_key, ca = os.path.join(directory, "ca.key"), os.path.join(directory, "ca.pem")
    key, csr, leaf = (os.path.join(directory, n) for n in ("leaf.key", "leaf.csr", "leaf.pem"))
    ca_cnf, leaf_ext = os.path.join(directory, "ca.cnf"), os.path.join(directory, "leaf.ext")
    with open(ca_cnf, "w") as handle:
        handle.write("[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\n"
                     "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
                     "subjectKeyIdentifier=hash\n")
    with open(leaf_ext, "w") as handle:
        handle.write("basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                     "extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost"
                     + (f",DNS:{PAGE_HOST}" if PAGE_HOST != "127.0.0.1" else "") + "\n")
    steps = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", ca_key, "-out", ca, "-days", "1",
         "-subj", f"/CN={CA_NAME}", "-config", ca_cnf],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", "/CN=127.0.0.1"],
        ["openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-out", leaf,
         "-days", "1", "-sha256", "-extfile", leaf_ext],
    ]
    try:
        for step in steps:
            result = run(step)
            if result.returncode:
                log(f"PAYMENTS certificate step failed: {' '.join(step[:3])}: {result.stderr.strip()[:300]}")
                return None
    finally:
        if os.path.exists(ca_key):
            os.remove(ca_key)
    return ca, leaf, key


def application_server_key(directory):
    """A P-256 public key (65 bytes, uncompressed), base64: what subscribe() wants of a server."""
    private = os.path.join(directory, "push.pem")
    if run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", private]).returncode:
        return None
    public = subprocess.run(["openssl", "ec", "-in", private, "-pubout", "-outform", "DER"], capture_output=True)
    os.remove(private)
    if public.returncode or len(public.stdout) < 65:
        return None
    return base64.b64encode(public.stdout[-65:]).decode()


class Trust:
    """The throwaway authority trusted for the run, and removed after: in the System keychain with
    sudo (`system`, CI), or in the user's login keychain (`user`: macOS asks for the user's
    password or Touch ID, to add and to remove it)."""

    TIMEOUT = 120

    def __init__(self, ca, where):
        self.ca = ca
        self.where = where
        self.added = False
        self.keeping = threading.Event()

    def security(self, *arguments):
        prefix = ["sudo", "-n"] if self.where == "system" else []
        return run(prefix + ["security", *arguments], timeout=self.TIMEOUT)

    def keychain(self):
        if self.where == "system":
            return "/Library/Keychains/System.keychain"
        return os.path.expanduser("~/Library/Keychains/login.keychain-db")

    def add(self):
        domain = ["-d"] if self.where == "system" else []
        result = self.security("add-trusted-cert", *domain, "-r", "trustRoot", "-k", self.keychain(), self.ca)
        self.added = result.returncode == 0
        log(f"PAYMENTS trust the throwaway authority ({self.where}): exit {result.returncode} {result.stderr.strip()[:200]}")
        if self.added and self.where == "system":
            # sudo's credentials last minutes; the run may take longer, and the removal needs them.
            threading.Thread(target=self.keep_sudo, daemon=True).start()
        return self.added

    def keep_sudo(self):
        while not self.keeping.wait(60):
            run(["sudo", "-n", "-v"])

    def remove(self):
        """Takes the authority's trust back and deletes it from the keychain. False, with what was
        left and what to do about it said, when the certificate is still there: a `security` that
        does not return (it waits for an authorization no one answers, as on a CI runner) is said
        as such, not taken for a side that did not report."""
        if not self.added:
            return True
        self.added = False
        domain = ["-d"] if self.where == "system" else []
        outcomes = []
        for step in (["remove-trusted-cert", *domain, self.ca], ["delete-certificate", "-c", CA_NAME, self.keychain()]):
            try:
                result = self.security(*step)
                outcomes.append((step[0], result.returncode == 0,
                                 f"exit {result.returncode}" + (f" {result.stderr.strip()[:200]}" if result.returncode else "")))
            except subprocess.TimeoutExpired:
                outcomes.append((step[0], False, f"did not return within {self.TIMEOUT} s"))
        self.keeping.set()
        said = "; ".join(f"{name}: {detail}" for name, _, detail in outcomes)
        deleted = outcomes[-1][1]
        if deleted:
            log(f"PAYMENTS the throwaway authority removed ({said})")
        else:
            log(f"PAYMENTS the throwaway authority NOT removed ({said}): remove \"{CA_NAME}\" from {self.keychain()} "
                "by hand. Its key was deleted before it was trusted, so nothing can be signed with it.")
        return deleted


class Pages:
    """The page, its service worker, and the reports, on 127.0.0.1 over HTTPS — or over HTTP with
    no certificate (`leaf` None), for the window's own property names alone: 127.0.0.1 is a secure
    context over HTTP too, so the same interfaces show, but Apple Pay answers no call there."""

    def __init__(self, leaf, key, push_key):
        self.reports = {}
        self.lock = threading.Lock()
        page = PAGE.replace("__INTERFACES__", json.dumps(INTERFACES)).replace("__KEY__", json.dumps(push_key))
        pages = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send(self, status, body, content_type="text/plain; charset=utf-8"):
                data = body.encode() if isinstance(body, str) else body
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def allowed(self):
                host = self.headers.get("Host", "")
                return host in (f"127.0.0.1:{pages.port}", f"localhost:{pages.port}", f"{PAGE_HOST}:{pages.port}")

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                query = urllib.parse.parse_qs(url.query)
                if not self.allowed():
                    return self.send(404, "")
                if url.path == "/pay":
                    return self.send(200, page, "text/html; charset=utf-8")
                if url.path == "/sw.js":
                    return self.send(200, SERVICE_WORKER, "text/javascript")
                if url.path == "/reported":
                    side = query.get("side", [""])[0]
                    with pages.lock:
                        return self.send(200, "yes" if side in pages.reports else "no")
                return self.send(404, "")

            def do_POST(self):
                url = urllib.parse.urlparse(self.path)
                side = urllib.parse.parse_qs(url.query).get("side", [""])[0]
                length = min(int(self.headers.get("Content-Length", "0") or 0), 4 * 1024 * 1024)
                body = self.rfile.read(length)
                if url.path == "/mark" and self.allowed():
                    # Round 3: a step of the page began or ended; Safari's sheet watcher acts on it.
                    query = urllib.parse.parse_qs(url.query)
                    step = query.get("step", ["?"])[0].replace(" ", "_")
                    phase = query.get("phase", ["?"])[0]
                    stamp = int(time.time() * 1000)
                    log(f"PAYMENTS mark {side} {phase} {step} at {stamp}")
                    trigger = os.environ.get("PB_SHEET_TRIGGER")
                    if trigger and side == "safari":
                        with open(trigger, "a") as handle:
                            handle.write(f"{phase} {step} {stamp}\n")
                    return self.send(200, "ok")
                if not self.allowed() or url.path != "/report" or not side:
                    return self.send(404, "")
                try:
                    report = json.loads(body)
                except ValueError:
                    return self.send(400, "")
                with pages.lock:
                    pages.reports.setdefault(side, report)
                return self.send(200, "ok")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.scheme = "https" if leaf else "http"
        if leaf:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(leaf, key)
            self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, side):
        return f"{self.scheme}://{PAGE_HOST}:{self.port}/pay?side={urllib.parse.quote(side)}"

    def wait(self, side, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if side in self.reports:
                    return self.reports[side]
            time.sleep(0.5)
        return None


def answer(call):
    if call is None:
        return "not measured"
    if call.get("ok"):
        return "-> " + json.dumps(call.get("value"), ensure_ascii=False)
    return f"throws {call.get('name')}: {call.get('message')}"


def compare(side, report, safari):
    """PAYMENTS lines for one side; then its summary, its calls in one line (Safari's every answer,
    a variant's where it differs from Safari's), and the window's names only one side has."""
    present = report.get("present", {})
    log(f"PAYMENTS {side}: window's own properties {report.get('windowOwnCount')}; "
        + "; ".join(f"{name} {present.get(name)}" for name in
                    ["ApplePaySession", "PaymentRequest", "PushManager", "safari", "window.pushManager"]))
    calls = report.get("calls", {})
    for name, call in calls.items():
        same = safari is not None and safari.get("calls", {}).get(name) == call
        mark = "same" if same else ("differs" if safari is not None else "")
        log(f"PAYMENTS {side} {name} {answer(call)} {mark}".rstrip())
    presence = (f"ApplePaySession {present.get('ApplePaySession')}, PaymentRequest {present.get('PaymentRequest')}, "
                f"PushManager {present.get('PushManager')}, window.safari {present.get('safari')}")
    if safari is None or side == "safari":
        summary = f"{side}: window {report.get('windowOwnCount')}; {presence}"
        calls_line = f"{side}: " + " | ".join(f"{name} {answer(call)}" for name, call in calls.items())
        return summary, calls_line, None
    names, safari_names = set(report.get("windowOwnNames", [])), set(safari.get("windowOwnNames", []))
    only_safari, only_here = sorted(safari_names - names), sorted(names - safari_names)
    log(f"PAYMENTS {side} only in Safari's window ({len(only_safari)}): {' '.join(only_safari)}")
    log(f"PAYMENTS {side} only in this window ({len(only_here)}): {' '.join(only_here)}")
    safari_calls = safari.get("calls", {})
    differing = [name for name in safari_calls if calls.get(name) != safari_calls[name]]
    summary = (f"{side}: window {report.get('windowOwnCount')} (Safari {safari.get('windowOwnCount')}); {presence}; "
               f"calls answered as Safari answers them: {len(safari_calls) - len(differing)} of {len(safari_calls)}")
    calls_line = f"{side}, where Safari answers otherwise: " + (
        " | ".join(f"{name} {answer(calls.get(name))}" for name in differing) if differing else "none")
    names_line = (f"{side}: only in Safari's window ({len(only_safari)}) {' '.join(only_safari) or '-'}; "
                  f"only in this one ({len(only_here)}) {' '.join(only_here) or '-'}")
    return summary, calls_line, names_line


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0].replace("\n", " "))
    parser.add_argument("--app", required=True, help="PrivacyBrowser.app, the build without the App Sandbox")
    parser.add_argument("--out", default="build/payments")
    parser.add_argument("--trust", choices=["system", "user"],
                        help="trust the throwaway authority for the run: in the System keychain (sudo), "
                             "or in the login keychain (macOS asks for the password or Touch ID)")
    parser.add_argument("--proxy", default="127.0.0.1:9", help="the profiles' HTTP proxy; 'none' for none")
    parser.add_argument("--variants", default=",".join(VARIANTS))
    parser.add_argument("--no-safari", action="store_true")
    parser.add_argument("--http", action="store_true",
                        help="serve the page over HTTP on 127.0.0.1, with no certificate and nothing trusted: for the "
                             "window's own property names (Apple Pay answers no call there)")
    options = parser.parse_args()

    executable = os.path.join(options.app, "Contents", "MacOS", "PrivacyBrowser")
    if not os.path.exists(executable):
        log(f"PAYMENTS no app at {options.app}")
        return 64
    variants = [v for v in options.variants.split(",") if v]
    unknown = [v for v in variants if v not in VARIANTS]
    if unknown:
        log(f"PAYMENTS unknown variants: {unknown}")
        return 64
    os.makedirs(options.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="pb-payments-")
    trusted = []
    try:
        code = measure(options, executable, variants, work, trusted)
    finally:
        removed = all([trust.remove() for trust in trusted])
        shutil.rmtree(work, ignore_errors=True)
    return code if code or removed else 3


def measure(options, executable, variants, work, trusted):
    """Serves the page, has Safari and every variant report, prints the comparison. The authority it
    trusts goes into `trusted`, for main to remove whatever happens here."""
    made = None if options.http else make_certificates(work)
    push_key = application_server_key(work)
    if (made is None and not options.http) or push_key is None:
        log("PAYMENTS could not make the certificates or the push key")
        return 1
    ca, leaf, key = made if made else (None, None, None)
    if options.trust and not options.http:
        trust = Trust(ca, options.trust)
        trusted.append(trust)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
        if not trust.add():
            log("PAYMENTS the authority could not be trusted: neither browser would load the page")
            return 1
    pages = Pages(leaf, key, push_key)
    log(f"PAYMENTS the page is served at {pages.scheme}://{PAGE_HOST}:{pages.port}/pay")

    safari = None
    if not options.no_safari:
        # Round 3: every window that comes or goes while Safari measures, and an Escape 3 s after each
        # of its ceremonies begins (scripts/measure/sheet_watch.swift), when CI built the watcher.
        watcher = None
        if os.environ.get("PB_SHEET_WATCH") and os.environ.get("PB_SHEET_TRIGGER"):
            open(os.environ["PB_SHEET_TRIGGER"], "w").close()
            watcher = subprocess.Popen([os.environ["PB_SHEET_WATCH"], os.environ["PB_SHEET_TRIGGER"], "300", os.path.abspath(options.out)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            time.sleep(1)
        subprocess.run(["open", "-b", "com.apple.Safari", pages.url("safari")])
        safari = pages.wait("safari", 240)
        log("PAYMENTS Safari " + ("reported" if safari else "did not report within 240 s"))
        if watcher:
            watcher.terminate()
            try:
                output, _ = watcher.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                watcher.kill()
                output, _ = watcher.communicate()
            for line in output.splitlines():
                log(line)

    missing = []
    for variant in variants:
        command = [executable, "--payments-check", "--url", pages.url(variant), "--variant", variant]
        if options.proxy != "none":
            command += ["--proxy", options.proxy]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=420)
            for line in result.stdout.splitlines():
                if line.startswith("PAYMENTS-CHECK"):
                    log(line)
        except subprocess.TimeoutExpired:
            log(f"PAYMENTS {variant}: the app did not finish within 420 s")
        if pages.wait(variant, 1) is None:
            missing.append(variant)

    lines = []
    if safari:
        lines.append(compare("safari", safari, safari))
    for variant in variants:
        report = pages.reports.get(variant)
        lines.append(compare(variant, report, safari) if report else (f"{variant}: no report", None, None))
    with open(os.path.join(options.out, "payments.json"), "w") as handle:
        json.dump(pages.reports, handle, indent=1, ensure_ascii=False)
    # Last, one kind to a line, so that CI can turn each kind into notices of its own.
    for prefix, index in (("PAYMENTS-SUMMARY", 0), ("PAYMENTS-CALLS", 1), ("PAYMENTS-NAMES", 2)):
        for line in lines:
            if line[index]:
                log(f"{prefix} {line[index]}")
    if missing:
        log(f"PAYMENTS no report from: {', '.join(missing)}")
        return 1
    return 0 if safari or options.no_safari else 2


if __name__ == "__main__":
    sys.exit(main())
