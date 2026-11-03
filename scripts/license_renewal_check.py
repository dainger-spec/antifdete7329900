#!/usr/bin/env python3
"""The license's renewal as the account server sees it — what reaches the server, not what the app
says it sent (the owner, 3 November: one `POST /v1/device/entitlement` in nine hours, at the
activation; a full relaunch, three profiles made, and nothing more).

    python3 scripts/license_renewal_check.py --app build/unsandboxed/Lumen.app --out build/license-renewal
    python3 scripts/license_renewal_check.py --app … --out … --measure

A stand-in for the account server on 127.0.0.1 answers the device's renewal (§6.2) with documents
signed by a key made for this run (scripts/entitlement_signer.swift) and keeps every request it
gets — when, with which fields — in `server-requests.jsonl`. The app is a development build, which
takes the server and the key from its environment (PB_ACCOUNT_SERVER_URL, PB_ENTITLEMENT_PUBLIC_KEYS;
AccountConfiguration), started as a person starts it and ended with SIGTERM (an Apple event would
wait on an automation prompt no one answers on a runner). Its vault folder is the run's own
(PRIVACYBROWSER_VAULT_DIR), signed in as after an activation: `account.json` with a device token and,
as the phase needs, a document.

Phases, each judged by the server's requests alone:

  launch     a document issued now (refresh after 24 h, as the contract's server issues them): the
             app started, then started again — the server must be asked at each start.
  due        a document whose refresh time has passed: asked at the start. The harness's own
             control — an app that cannot reach the stand-in at all fails here first.
  periodic   documents whose refresh time is a minute after they are issued, the app left running:
             asked again after each, without a start.
  failure    the server answers 500: the app's own log (subsystem PrivacyBrowser, category License)
             must say the renewal failed — silence is not success.
  control    the app given a server address where nothing listens: the stand-in sees nothing, and
             the launch's verdict must be FAIL — the check can fail, and fails by the server.
  profiles   (when the build has `--selftest-license-renewal`) a vault with three profiles opened
             with its password through the app's own model, then a fourth made: the server must be
             told 3, then 4.

Every request must carry the app's version (`<version> (<build>)`), this Mac's id and its name
(`scutil --get ComputerName`) as the label.

`--measure` says what this build does — every request with its time since the start, over 17
minutes of running for `periodic` — and fails only when the harness itself did not work (the
`due` phase saw nothing). Without it, every requirement above is a check: exit 1 on any FAIL.
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
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail else ""), flush=True)
    if not ok:
        failures.append(name)
    return ok


def info(text):
    print("INFO " + text, flush=True)


def rfc3339(t):
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# MARK: The key and the documents

class Signer:
    def __init__(self, out):
        self.binary = os.path.join(out, "entitlement-signer")
        subprocess.run(["swiftc", "-O", os.path.join(ROOT, "scripts", "entitlement_signer.swift"), "-o", self.binary], check=True)
        self.key = os.path.join(out, "entitlement.key")
        made = subprocess.run([self.binary, "keygen", self.key], check=True, capture_output=True, text=True).stdout
        meta = json.loads(made)
        self.key_id = meta["keyID"]
        self.public_key = meta["publicKey"]

    def sign(self, payload):
        return subprocess.run([self.binary, "sign", self.key], input=payload, check=True,
                              capture_output=True).stdout.decode().strip()


class Stub:
    """The account server's renewal (§6.2), and a record of every request it got."""

    def __init__(self, signer, device_id, token, log_path):
        self.signer = signer
        self.device_id = device_id
        self.token = token
        self.log_path = log_path
        self.lock = threading.Lock()
        self.requests = []
        self.mode = "ok"
        self.refresh_after = 24 * 3600
        self.expires = 96 * 3600
        self.grace = 168 * 3600
        self.period_ends = time.time() + 30 * 86400
        self.issued = 0

    def document(self, machine_id, issued):
        with self.lock:
            self.issued += 1
            number = self.issued
            refresh_after, expires, grace = self.refresh_after, self.expires, self.grace
        payload = {
            "kind": "lumen.entitlement", "version": 1, "documentID": f"doc-renewal-check-{number}",
            "accountID": "acc-renewal-check", "licenseID": "lic-renewal-check",
            "deviceID": self.device_id, "machineID": machine_id, "role": "owner", "plan": "personal",
            "status": "active", "exportReason": None, "limits": {"profiles": 50, "devices": 3, "seats": 1},
            "profilesOnOtherDevices": 0, "periodEndsAt": rfc3339(self.period_ends),
            "issuedAt": rfc3339(issued), "refreshAfter": rfc3339(issued + refresh_after),
            "expiresAt": rfc3339(issued + expires), "graceEndsAt": rfc3339(issued + grace),
        }
        data = json.dumps(payload, separators=(",", ":")).encode()
        return {"format": 1, "keyID": self.signer.key_id, "payload": base64.b64encode(data).decode(),
                "signature": self.signer.sign(data)}

    def handle(self, method, path, headers, body):
        now = time.time()
        try:
            fields = json.loads(body.decode() or "{}") if body else {}
        except ValueError:
            fields = {"unreadable": True}
        authorized = headers.get("Authorization") == "Bearer " + self.token
        record = {"t": now, "method": method, "path": path, "authorized": authorized,
                  "profileCount": fields.get("profileCount"), "appVersion": fields.get("appVersion"),
                  "label": fields.get("label"), "hasLabel": "label" in fields,
                  "machineID": fields.get("machineID"), "fields": sorted(fields.keys()),
                  "userAgent": headers.get("User-Agent")}
        if method == "POST" and path == "/v1/device/entitlement":
            if not authorized:
                status, answer = 401, {"error": {"code": "unauthorized", "message": "no such device token"}}
            elif self.mode == "down":
                status, answer = 500, {"error": {"code": "internal", "message": "down for the check"}}
            else:
                status = 200
                answer = {"entitlement": self.document(fields.get("machineID", ""), now),
                          "serverTime": rfc3339(now), "unlinkCooldownSeconds": 0}
        else:
            status, answer = 404, {"error": {"code": "not_found", "message": path}}
        record["status"] = status
        with self.lock:
            self.requests.append(record)
            with open(self.log_path, "a") as handle:
                handle.write(json.dumps(record) + "\n")
        return status, answer

    def renewals(self, since, until=None):
        with self.lock:
            return [r for r in self.requests if r["path"] == "/v1/device/entitlement" and r["method"] == "POST"
                    and r["t"] >= since and (until is None or r["t"] <= until)]


def serve(stub):
    class Handler(BaseHTTPRequestHandler):
        def respond(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            status, answer = stub.handle(method, self.path, dict(self.headers), body)
            data = json.dumps(answer).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            self.respond("POST")

        def do_GET(self):
            self.respond("GET")

        def do_DELETE(self):
            self.respond("DELETE")

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# MARK: This Mac and the app

def this_machine_id():
    text = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout
    found = re.search(r'"IOPlatformUUID" = "([^"]+)"', text)
    if not found:
        return None
    return hashlib.sha256(("lumen.machine-id.v1\n" + found.group(1).upper()).encode()).hexdigest()


def computer_name():
    return subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()


def app_version(info_plist):
    # AccountAPI.appVersion: "<version> (<build>)", only these characters, at most 32 of them.
    text = f"{info_plist.get('CFBundleShortVersionString', '0')} ({info_plist.get('CFBundleVersion', '0')})"
    allowed = set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-_ ()")
    return "".join(c for c in text if c in allowed)[:32]


def seed(vault, device_id, token, envelope):
    """account.json as an activation leaves it (§4.2): the device, its token and, here, a document."""
    os.makedirs(vault, exist_ok=True)
    record = {"format": 1, "deviceID": device_id, "code": "RC01", "deviceToken": token, "appOutdated": False,
              "signedInWith": "email"}
    if envelope is not None:
        record["entitlement"] = envelope
    path = os.path.join(vault, "account.json")
    if os.path.exists(path):
        os.remove(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(record, handle)


class Run:
    """One start of the app, as a person starts it; ended with SIGTERM."""

    def __init__(self, executable, environment, log_path, arguments=()):
        self.log = open(log_path, "w")
        self.started = time.time()
        self.process = subprocess.Popen([executable, *arguments], env=environment, stdout=self.log,
                                        stderr=subprocess.STDOUT)

    def end(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(10)
        self.log.close()
        return self.process.returncode


def app_log(since, out, name):
    """What the app's own log said about the license since `since`: the unified log, as the owner reads it."""
    start = datetime.datetime.fromtimestamp(since - 2).strftime("%Y-%m-%d %H:%M:%S")
    text = subprocess.run(["log", "show", "--style", "compact", "--start", start, "--predicate",
                           'subsystem == "PrivacyBrowser" AND category == "License"'],
                          capture_output=True, text=True).stdout
    lines = [line for line in text.splitlines() if "PrivacyBrowser" in line or "License" in line]
    with open(os.path.join(out, f"app-log-{name}.txt"), "w") as handle:
        handle.write(text)
    return lines


def describe(requests, since):
    return ", ".join(f"+{r['t'] - since:.0f} s ({r['status']}, profiles {r['profileCount']}, "
                     f"label {'given' if r['hasLabel'] else 'none'})" for r in requests) or "none"


# MARK: The phases

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--phases", default="launch,due,periodic,failure,control,profiles")
    arguments = parser.parse_args()
    measure = arguments.measure
    phases = arguments.phases.split(",")
    out = os.path.abspath(arguments.out)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)

    with open(os.path.join(arguments.app, "Contents", "Info.plist"), "rb") as handle:
        plist = plistlib.load(handle)
    if plist.get("PBAccountServerURL"):
        print("FAIL this build names its own account server: only a development build takes the stand-in's "
              "(build it without ACCOUNT_SERVER_URL)")
        return 1
    executable = os.path.join(arguments.app, "Contents", "MacOS", plist["CFBundleExecutable"])
    machine_id = this_machine_id()
    name = computer_name()
    version = app_version(plist)
    info(f"app {arguments.app}, version {version!r}, this Mac's name {name!r}, machine id "
         f"{'computed' if machine_id else 'NOT computed'}")
    if not machine_id:
        print("FAIL this Mac's IOPlatformUUID could not be read: no document can be made for it")
        return 1

    signer = Signer(out)
    device_id = "dev-renewal-check"
    token = "lmd_renewalcheck_" + uuid.uuid4().hex
    stub = Stub(signer, device_id, token, os.path.join(out, "server-requests.jsonl"))
    server = serve(stub)
    url = f"http://127.0.0.1:{server.server_address[1]}"
    info(f"the stand-in server at {url}, key {signer.key_id}")

    def environment(vault, server_url=url):
        env = dict(os.environ)
        env.update({"PRIVACYBROWSER_VAULT_DIR": vault, "PB_ACCOUNT_SERVER_URL": server_url,
                    "PB_ENTITLEMENT_PUBLIC_KEYS": f"{signer.key_id}={signer.public_key}"})
        return env

    def document_issued(at, refresh_after=24 * 3600):
        stub.refresh_after = refresh_after
        return stub.document(machine_id, at)

    def fields_hold(requests, what, profiles=None):
        """Every request this phase got carries the version, this Mac's id and its name."""
        if measure or not requests:
            return
        check(f"{what}: each request carries the app's version ({version})",
              all(r["appVersion"] == version for r in requests), str([r["appVersion"] for r in requests]))
        check(f"{what}: each request carries this Mac's id", all(r["machineID"] == machine_id for r in requests))
        check(f"{what}: each request carries this Mac's name as its label",
              all(r["label"] == name for r in requests),
              str([("none" if not r["hasLabel"] else ("this Mac's name" if r["label"] == name else "another"))
                   for r in requests]))
        if profiles is not None:
            check(f"{what}: each request says {profiles} profile(s)",
                  all(r["profileCount"] == profiles for r in requests), str([r["profileCount"] for r in requests]))

    wait_launch = 90 if measure else 45

    # The owner's case: a document issued now, then a relaunch.
    if "launch" in phases:
        vault = os.path.join(out, "vault-launch")
        stub.mode = "ok"
        seed(vault, device_id, token, document_issued(time.time()))
        for number in (1, 2):
            run = Run(executable, environment(vault), os.path.join(out, f"app-launch-{number}.log"))
            time.sleep(wait_launch)
            seen = stub.renewals(run.started)
            status = run.end()
            said = app_log(run.started, out, f"launch-{number}")
            info(f"launch {number} (a fresh document): the server saw {describe(seen, run.started)}; "
                 f"the app's License log: {len(said)} line(s); ended with {status}")
            if not measure:
                check(f"start {number} with a fresh document: the server is asked within {wait_launch} s", len(seen) >= 1,
                      f"{len(seen)} request(s)")
                fields_hold(seen, f"start {number}", profiles=0)

    # The harness's own control: a document whose refresh time has passed is renewed at the start
    # by any build — the stand-in, the key and the app's environment work.
    if "due" in phases:
        vault = os.path.join(out, "vault-due")
        stub.mode = "ok"
        seed(vault, device_id, token, document_issued(time.time() - 25 * 3600))
        run = Run(executable, environment(vault), os.path.join(out, "app-due.log"))
        time.sleep(60)
        seen = stub.renewals(run.started)
        status = run.end()
        info(f"due (refresh time passed an hour ago): the server saw {describe(seen, run.started)}; ended with {status}")
        harness = len(seen) >= 1 and all(r["status"] == 200 for r in seen)
        if not check("the harness works: a document past its refresh time is renewed at the start (200)", harness,
                     describe(seen, run.started)):
            return 1

    # While the app runs: each document asks to be renewed a minute after it is issued.
    if "periodic" in phases:
        vault = os.path.join(out, "vault-periodic")
        stub.mode = "ok"
        refresh = 120 if measure else 60
        seed(vault, device_id, token, document_issued(time.time() - 25 * 3600))
        stub.refresh_after = refresh
        duration = 17 * 60 if measure else 4 * 60
        run = Run(executable, environment(vault), os.path.join(out, "app-periodic.log"))
        time.sleep(duration)
        seen = stub.renewals(run.started)
        status = run.end()
        gaps = [b["t"] - a["t"] for a, b in zip(seen, seen[1:])]
        info(f"periodic (each document's refresh time {refresh} s after it is issued, {duration // 60} minutes "
             f"running): the server saw {describe(seen, run.started)}; between them "
             f"{', '.join(f'{gap:.0f} s' for gap in gaps) or 'nothing'}; ended with {status}")
        if not measure:
            check(f"running, the document is renewed after its refresh time without a start: "
                  f"at least 2 renewals after the first in {duration // 60} minutes", len(seen) >= 3, f"{len(seen)} in all")
            check(f"running, no renewal later than {refresh + 90} s after the one before",
                  bool(gaps) and max(gaps) <= refresh + 90, ", ".join(f"{gap:.0f} s" for gap in gaps))
            fields_hold(seen, "periodic", profiles=0)
        stub.refresh_after = 24 * 3600

    if measure:
        print(f"MEASURED: {len(stub.renewals(0))} renewal(s) in all; server-requests.jsonl has every request")
        return 0

    # A renewal that fails is said in the app's own log.
    if "failure" in phases:
        vault = os.path.join(out, "vault-failure")
        seed(vault, device_id, token, document_issued(time.time()))
        stub.mode = "down"
        run = Run(executable, environment(vault), os.path.join(out, "app-failure.log"))
        time.sleep(45)
        seen = stub.renewals(run.started)
        status = run.end()
        stub.mode = "ok"
        said = app_log(run.started, out, "failure")
        failed = [line for line in said if "renewal failed" in line.lower()]
        info(f"failure (the server answers 500): the server saw {describe(seen, run.started)}; the app's log said "
             f"{len(said)} line(s); ended with {status}")
        check("a renewal the server refused (500) is attempted at the start", len(seen) >= 1, f"{len(seen)} request(s)")
        check("the app's own log says the renewal failed (subsystem PrivacyBrowser, category License)", bool(failed),
              (failed[0][-200:] if failed else "nothing about a failure among " + str(len(said)) + " line(s)"))

    # The control: the check fails when nothing reaches the server.
    if "control" in phases:
        vault = os.path.join(out, "vault-control")
        seed(vault, device_id, token, document_issued(time.time()))
        run = Run(executable, environment(vault, "http://127.0.0.1:9"), os.path.join(out, "app-control.log"))
        time.sleep(30)
        seen = stub.renewals(run.started)
        run.end()
        verdict_would_pass = len(seen) >= 1
        info(f"control (the app given an address where nothing listens): the server saw {describe(seen, run.started)}")
        check("the control: with nothing reaching the server, the start's check would FAIL", not verdict_would_pass,
              f"{len(seen)} request(s) seen")

    # The real number of profiles, through the app's own model (a build that has the scenario).
    if "profiles" in phases:
        vault = os.path.join(out, "vault-profiles")
        seed(vault, device_id, token, document_issued(time.time()))
        environment_profiles = environment(vault)
        environment_profiles["PB_SELFTEST_LICENSE_RENEWAL"] = "1"
        run = Run(executable, environment_profiles, os.path.join(out, "app-profiles.log"),
                  ["--selftest-license-renewal"])
        try:
            run.process.wait(180)
        except subprocess.TimeoutExpired:
            pass
        status = run.end()
        with open(os.path.join(out, "app-profiles.log")) as handle:
            said = handle.read()
        for line in said.splitlines():
            if line.startswith("LICENSE-RENEWAL"):
                print("  " + line, flush=True)
        seen = stub.renewals(run.started)
        counts = [r["profileCount"] for r in seen]
        info(f"profiles: the server saw {describe(seen, run.started)}; the scenario ended with {status}")
        if "LICENSE-RENEWAL usage" in said or status == 64:
            check("the build has the scenario --selftest-license-renewal", False, "it does not")
        else:
            check("the scenario ran to its end", status == 0, f"exit status {status}")
            check("after the vault opened, the server is told its 3 profiles", 3 in counts, str(counts))
            check("after a fourth profile is made, the server is told 4", 4 in counts, str(counts))
            check("the server is never told fewer profiles after it was told the real number",
                  all(c >= 3 for c in counts[counts.index(3):]) if 3 in counts else False, str(counts))
            fields_hold(seen, "profiles")

    server.shutdown()
    print(f"LICENSE RENEWAL CHECK {'PASSED' if not failures else 'FAILED'}: {len(failures)} failed"
          + (": " + "; ".join(failures) if failures else ""), flush=True)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
