#!/usr/bin/env python3
"""The update scenarios of docs/UPDATES.md §8, end to end on this Mac — CI's throwaway runner.

    python3 scripts/update_check.py --variant sandboxed --out build/update-sandboxed
    python3 scripts/update_check.py --variant unsandboxed --out build/update-unsandboxed

It makes everything an update needs, the way scripts/release.sh would, but locally:

* an Ed25519 key (`pbupdate keygen`), and two builds of the app under its own bundle id
  (dev.local.PBUpdateCheck): the old one (0.1.0, build 1) and the new one (0.1.1, build 2), both
  with this feed and key built in;
* the new build zipped and signed, and appcasts made in this order, a second apart: "stale" (the
  real release, oldest), "downgrade" (only build 1 and 0.9), "valid" (the real release, newest);
  "forged" is "valid" with its list changed under its signature; "tampered" serves "valid" with
  one byte of the zip changed;
* a local HTTPS feed, like scripts/selftest_proxy.py for the proxies: `/appcast.json` serves what
  `/__control/serve?mode=…` asks for, `/__control/hits` counts the appcast's requests, and every
  request of the app is kept, headers included. Its certificate is self-signed for localhost; a
  runner's trust settings cannot be changed without someone at the screen (`security
  authorizationdb write` is refused, -60005), so the app under test is given that one
  certificate's SHA-256 (`PB_SELFTEST_UPDATE_CERT_SHA256`, honoured by the scenario mode only).

Then the old build runs `--selftest-updates run` (UpdateSelfTest.swift), under a packet capture with
each packet's process (pktap): no request with automatic checks off — checked by the capture too,
whose control is the first request once they are on — the older build never offered, the stale and
forged appcasts and the changed archive refused, the release downloaded, nothing handed over while
a profile with a window and a warm-up without one run, then the quit path, the gate and the real
installer helper. This script waits for the swap (the old build's folder holds build 2), looks at
the vault on disk at that moment, waits for the new build to be started by the helper and for the
helper's own word ("Update: installed") in the unified log, quits it, and runs the new build's
`--selftest-updates verify`: the old build's vault, profiles and data open. Every request the feed
got must carry the same headers from any Mac — no cookie, no query, User-Agent "PrivacyBrowser".

It replaces an app and captures packets (sudo): a CI runner's job only. Exit code 1 on any failure.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress_check  # noqa: E402  (pktap lines with their process: egress_check.parse)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE_ID = "dev.local.PBUpdateCheck"
OLD = ("0.1.0", "1")
NEW = ("0.1.1", "2")
CERT_NAME = "PBUpdateCheck localhost"

failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else f" — {detail}"), flush=True)
    if not ok:
        failures.append(name)


def run(command, **kwargs):
    print("+ " + " ".join(command), flush=True)
    return subprocess.run(command, check=True, **kwargs)


# MARK: The feed

class Feed:
    def __init__(self, appcasts, archive_name, archive, tampered):
        self.appcasts, self.archive_name, self.archive, self.tampered = appcasts, archive_name, archive, tampered
        self.mode, self.hits, self.requests, self.lock = "valid", 0, [], threading.Lock()


def handler_for(feed):
    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.0: every connection is closed after its answer, so none is left open — and none
        # closes — inside the window in which the app must send nothing.
        def log_message(self, *args):
            pass

        def answer(self, code, body, kind):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/__control/serve":
                feed.mode = parse_qs(url.query).get("mode", ["valid"])[0]
                return self.answer(200, b"ok", "text/plain")
            if url.path == "/__control/hits":
                return self.answer(200, str(feed.hits).encode(), "text/plain")
            with feed.lock:
                feed.requests.append({"path": self.path, "mode": feed.mode, "time": time.time(),
                                      "headers": {k: v for k, v in self.headers.items()}})
                if url.path == "/appcast.json":
                    feed.hits += 1
            if url.path == "/appcast.json":
                return self.answer(200, feed.appcasts[feed.mode], "application/json")
            if url.path == "/" + feed.archive_name:
                return self.answer(200, feed.tampered if feed.mode == "tampered" else feed.archive, "application/zip")
            return self.answer(404, b"not here", "text/plain")
    return Handler


class Server6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def serve(feed, port, cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    servers = []
    for cls, host in ((ThreadingHTTPServer, "127.0.0.1"), (Server6, "::1")):
        try:
            server = cls((host, port), handler_for(feed))
        except OSError as error:
            print(f"INFO no feed on {host}: {error}")
            continue
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    return servers


# MARK: Making the releases

def pbupdate():
    run(["swift", "build", "-c", "release", "--product", "pbupdate"], cwd=ROOT)
    bin_path = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout.strip()
    return os.path.join(bin_path, "pbupdate")


def build_app(folder, version, build, sandbox, feed_url, public_key):
    environment = dict(os.environ, BUNDLE_ID=BUNDLE_ID, SANDBOX="1" if sandbox else "0", APP_DIR=folder,
                       APP_VERSION=version, APP_BUILD=build, UPDATE_FEED_URL=feed_url, UPDATE_PUBLIC_KEYS=public_key)
    run([os.path.join(ROOT, "scripts/build-app.sh")], cwd=ROOT, env=environment)
    return os.path.join(folder, "PrivacyBrowser.app")


def item(tool, key, archive, version, build, url, notes):
    return run([tool, "item", "--key", key, "--archive", archive, "--version", version, "--build", build,
                "--minimum-system", "14.0", "--url", url, "--notes-file", notes], capture_output=True, text=True).stdout


def appcast(tool, key, out, items):
    paths = []
    for index, text in enumerate(items):
        path = f"{out}.item{index}.json"
        with open(path, "w") as handle:
            handle.write(text)
        paths.append(path)
    run([tool, "appcast", "--key", key, "--out", out] + paths)
    with open(out, "rb") as handle:
        return handle.read()


def forged(envelope_bytes, port):
    """The list changed under its signature: the release now points somewhere else."""
    envelope = json.loads(envelope_bytes)
    payload = json.loads(base64.b64decode(envelope["payload"]))
    payload["items"][0]["url"] = f"https://localhost:{port}/elsewhere.zip"
    envelope["payload"] = base64.b64encode(json.dumps(payload).encode()).decode()
    return json.dumps(envelope).encode()


# MARK: The run

def app_processes(app):
    found = subprocess.run(["pgrep", "-f", os.path.join(app, "Contents/MacOS/PrivacyBrowser")],
                           capture_output=True, text=True).stdout.split()
    return [int(pid) for pid in found]


def wait(seconds, condition, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(step)
    return condition()


def build_number(app):
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as handle:
            return plistlib.load(handle).get("CFBundleVersion")
    except (OSError, plistlib.InvalidFileException):
        return None


def plaintext_left(vault, profile_ids, roots):
    """What of the profiles is in plaintext on disk: Safari's home in the vault, and website data —
    a folder named after the profile — under WebKit's roots (as WebKitDataLayout finds it)."""
    left, unreadable = [], []
    names = {u.lower() for u in profile_ids}
    for uuid in profile_ids:
        for name in ("home.noindex", "home"):
            if os.path.exists(os.path.join(vault, "profiles", uuid, name)):
                left.append(f"{uuid}/{name}")
    for root in roots:
        if not os.path.isdir(root):
            continue
        for path, directories, _ in os.walk(root, onerror=lambda error: unreadable.append(str(error))):
            left.extend(os.path.join(path, d) for d in directories if d.lower() in names)
            if path.count(os.sep) - root.count(os.sep) >= 4:
                directories[:] = []
    return left, unreadable


def stop_capture(capture):
    """tcpdump runs under sudo, which does not pass on a signal sent from our own process group:
    the capture is stopped by name, as root, as the self-test's step does."""
    if capture is None or capture.poll() is not None:
        return
    subprocess.run(["sudo", "pkill", "-INT", "-f", "tcpdump -i pktap"])
    try:
        capture.wait(timeout=30)
    except subprocess.TimeoutExpired:
        subprocess.run(["sudo", "pkill", "-KILL", "-f", "tcpdump -i pktap"])
        try:
            capture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            print("INFO the capture did not stop", flush=True)


def windows(log, name):
    begins = [float(t) for t in re.findall(rf"INFO {name} begin ([\d.]+)", log)]
    ends = [float(t) for t in re.findall(rf"INFO {name} end ([\d.]+)", log)]
    return list(zip(begins, ends))


def destination_port(line):
    flow = egress_check.FLOW.search(line)
    if not flow:
        return None
    end = flow.group(2).rstrip(":")
    tail = end.rsplit(".", 1)[-1]
    return int(tail) if tail.isdigit() else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=("sandboxed", "unsandboxed"), required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--port", type=int, default=18443)
    args = parser.parse_args()
    sandboxed = args.variant == "sandboxed"
    out = os.path.abspath(args.out)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    home = os.path.expanduser("~")
    feed_url = f"https://localhost:{args.port}/appcast.json"

    # The key, and the certificate the local feed is served with.
    tool = pbupdate()
    key = os.path.join(out, "update.key")
    key_id, public = run([tool, "keygen", key], capture_output=True, text=True).stdout.split()
    cert, cert_key = os.path.join(out, "feed.pem"), os.path.join(out, "feed.key")
    run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", cert_key, "-out", cert,
         "-days", "7", "-subj", f"/CN={CERT_NAME}",
         "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1",
         "-addext", "extendedKeyUsage=serverAuth"])
    with open(cert) as handle:
        cert_sha256 = hashlib.sha256(ssl.PEM_cert_to_DER_cert(handle.read())).hexdigest()

    capture = None
    try:
        # The old build and the new one.
        old_app = build_app(os.path.join(out, "old"), *OLD, sandboxed, feed_url, f"{key_id}={public}")
        new_app = build_app(os.path.join(out, "new"), *NEW, sandboxed, feed_url, f"{key_id}={public}")
        archive_name = f"PrivacyBrowser-{NEW[0]}.zip"
        new_zip, old_zip = os.path.join(out, archive_name), os.path.join(out, f"PrivacyBrowser-{OLD[0]}.zip")
        run(["ditto", "-c", "-k", "--keepParent", new_app, new_zip])
        run(["ditto", "-c", "-k", "--keepParent", old_app, old_zip])
        notes = os.path.join(out, "notes.txt")
        with open(notes, "w") as handle:
            handle.write("The update check's release.\n")
        base = f"https://localhost:{args.port}/"
        release = item(tool, key, new_zip, *NEW, base + archive_name, notes)
        same = item(tool, key, old_zip, *OLD, base + os.path.basename(old_zip), notes)
        older = item(tool, key, old_zip, "0.0.9", "0.9", base + "PrivacyBrowser-0.0.9.zip", notes)
        appcasts = {"stale": appcast(tool, key, os.path.join(out, "stale.json"), [release])}
        time.sleep(1.2)
        appcasts["downgrade"] = appcast(tool, key, os.path.join(out, "downgrade.json"), [same, older])
        time.sleep(1.2)
        appcasts["valid"] = appcast(tool, key, os.path.join(out, "valid.json"), [release])
        appcasts["tampered"] = appcasts["valid"]
        appcasts["forged"] = forged(appcasts["valid"], args.port)
        with open(new_zip, "rb") as handle:
            archive = handle.read()
        tampered = bytearray(archive)
        tampered[len(tampered) // 2] ^= 0xFF
        feed = Feed(appcasts, archive_name, archive, bytes(tampered))
        servers = serve(feed, args.port, cert, cert_key)
        check("the local feed listens", bool(servers))

        # Packets, each with its process (pktap), for as long as the old build runs.
        capture_path = os.path.join(out, "capture.txt")
        capture_file, capture_errors = open(capture_path, "w"), open(os.path.join(out, "tcpdump.err"), "w")
        capture = subprocess.Popen(["sudo", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l"],
                                   stdout=capture_file, stderr=capture_errors)
        time.sleep(2)

        stamp = datetime.datetime.now().strftime("%H%M%S")
        if sandboxed:
            # Inside the container: the only place the sandboxed build may keep a vault.
            container = os.path.join(home, f"Library/Containers/{BUNDLE_ID}/Data")
            vault = os.path.join(container, f"update-vault-{stamp}")
            roots = [os.path.join(container, "Library/WebKit"), os.path.join(container, "Library/Caches")]
        else:
            vault = os.path.join(out, "vault")
            roots = [os.path.join(home, "Library/WebKit", BUNDLE_ID), os.path.join(home, "Library/Caches", BUNDLE_ID)]
        binary = os.path.join(old_app, "Contents/MacOS/PrivacyBrowser")
        environment = dict(os.environ, PB_SELFTEST_UPDATES="1", PRIVACYBROWSER_VAULT_DIR=vault,
                           PB_SELFTEST_UPDATE_CONTROL=f"https://localhost:{args.port}/__control",
                           PB_SELFTEST_UPDATE_CERT_SHA256=cert_sha256)
        run_log = os.path.join(out, "run.txt")
        print("::group::the old build: --selftest-updates run", flush=True)
        with open(run_log, "w") as handle:
            code = subprocess.run([binary, "--selftest-updates", "run"], env=environment, stdout=handle,
                                  stderr=subprocess.STDOUT, timeout=420).returncode
        log = open(run_log, encoding="utf-8", errors="replace").read()
        print(log)
        print("::endgroup::", flush=True)
        check("the old build's scenarios passed", code == 0 and "SELFTEST-UPDATES run PASSED" in log, f"exit {code}")
        profile_ids = re.findall(r"INFO profile \S+ ([0-9A-F-]{36})", log)
        handed = "INFO handed-over" in log

        # The swap: the old build's folder now holds the new one.
        swapped = handed and wait(180, lambda: build_number(old_app) == NEW[1])
        check("the installer replaced the old build with the new one", swapped, f"build {build_number(old_app)}")
        if swapped:
            left, unreadable = plaintext_left(vault, profile_ids, roots)
            check("at the swap, no profile's data is in plaintext on disk", not left, ", ".join(left))
            if unreadable:
                print(f"INFO part of the disk could not be read from outside the app ({len(unreadable)}): "
                      "the app's own gate checked it at the hand-over")
        relaunched = swapped and wait(60, lambda: bool(app_processes(old_app)))
        check("the installer started the new build", relaunched)
        said = subprocess.run(["log", "show", "--last", "15m", "--style", "compact", "--predicate",
                               'subsystem == "PrivacyBrowser" AND category == "Updater"'],
                              capture_output=True, text=True).stdout
        print("::group::the installer's log", flush=True)
        print(said[-4000:])
        print("::endgroup::", flush=True)
        check("the installer says it installed the update", "Update: installed" in said)
        if relaunched:
            # Nothing of it runs (its own vault is elsewhere and locked): SIGTERM, not an Apple Event,
            # which would wait on an automation prompt no one answers here.
            for pid in app_processes(old_app):
                os.kill(pid, 15)
            check("the new build, started by the installer, quits", wait(30, lambda: not app_processes(old_app)))

        # The new build opens the old one's data.
        if swapped:
            verify_log = os.path.join(out, "verify.txt")
            environment = dict(environment, PB_SELFTEST_UPDATE_BUILD=NEW[1])
            with open(verify_log, "w") as handle:
                code = subprocess.run([binary, "--selftest-updates", "verify"], env=environment, stdout=handle,
                                      stderr=subprocess.STDOUT, timeout=300).returncode
            verified = open(verify_log, encoding="utf-8", errors="replace").read()
            print("::group::the new build: --selftest-updates verify", flush=True)
            print(verified)
            print("::endgroup::", flush=True)
            check("the new build opens the old build's data", code == 0 and "SELFTEST-UPDATES verify PASSED" in verified,
                  f"exit {code}")

        # The capture: not one packet of the app while checks were off; the control seen.
        stop_capture(capture)
        capture_file.close()
        packets = [egress_check.parse(line) for line in open(capture_path, encoding="utf-8", errors="replace")
                   if egress_check.TIME.search(line)]

        def ours(packet):
            return any(owner and owner[0].startswith("PrivacyBrowser") for owner in (packet["proc"], packet["eproc"]))

        off = windows(log, "egress-window")
        control = windows(log, "feed-control-window")
        quiet = [p for p in packets if ours(p) and any(b <= (p["time"] or 0) <= e for b, e in off)]
        seen = [p for p in packets if ours(p) and destination_port(p["line"]) == args.port
                and any(b <= (p["time"] or 0) <= e for b, e in control)]
        print(f"INFO capture: {len(packets)} packets, {sum(1 for p in packets if p['proc'])} with a process; "
              f"checks-off window {off}, control window {control}")
        check("the capture saw the app's request once checks were on (its control)", bool(seen) and bool(control))
        check("automatic checks off: not one packet of the app in the capture", bool(off) and not quiet,
              "; ".join(p["line"][:160] for p in quiet[:5]))

        # What the feed was sent: the same from every Mac.
        requests = list(feed.requests)
        check("the feed was asked for the appcast and the archive", any(r["path"] == "/appcast.json" for r in requests)
              and any(r["path"] == "/" + archive_name for r in requests))
        for request in requests:
            headers = {k.lower(): v for k, v in request["headers"].items()}
            problems = []
            if "?" in request["path"]:
                problems.append("a query string")
            if headers.get("user-agent") != "PrivacyBrowser":
                problems.append(f"User-Agent {headers.get('user-agent')!r}")
            if "cookie" in headers or "authorization" in headers:
                problems.append("a cookie or credentials")
            if headers.get("accept-language") != "en":
                problems.append(f"Accept-Language {headers.get('accept-language')!r}")
            check(f"request {request['path']} ({request['mode']}) carries nothing of this Mac", not problems,
                  ", ".join(problems) + f" — {headers}")
        with open(os.path.join(out, "requests.json"), "w") as handle:
            json.dump(requests, handle, indent=1)
    finally:
        stop_capture(capture)

    print(f"UPDATE CHECK ({args.variant}) {'PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
