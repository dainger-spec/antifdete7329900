#!/usr/bin/env python3
"""The real-iPhone tooling's own checks, the ones that need no Mac (device-tools.yml runs them).

    python3 ios-measure/test_tools.py <an ios-measure directory>

Run on this tree it must pass; run on the tree before the owner's fixes (8 November) it must fail —
device-tools.yml does both, so each check is seen red before it is trusted:
  - the harness, while it waits for the app, says so every 15 s with the time left (before: silent);
  - the harness on a busy port says which and what to do, without a traceback (before: a traceback,
    after the build, the install and sudo);
  - ports_free.py names a busy port before anything slow, and passes free ones (before: none);
  - check_app.py refuses a built app whose bundle id is not the one to launch (before: none);
  - a run whose capture saw nothing is not a success (before: "16/16 core checks passed");
  - the capture is looked at before the build: a recording that sees nothing, or the iPhone's VPN,
    stops the run (before: the build, the install and a whole run on a blind rvi0);
  - the summary names what it did not measure (before: INCONCLUSIVE checks vanished from it).
"""
import os
import plistlib
import socket
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)))
HOST = os.path.join(ROOT, "host")
PORTS = ["--control-port", "38310", "--http-port", "38380", "--https-port", "38443", "--port-a", "38381",
         "--port-b", "38382", "--port-f", "38384", "--stun-port", "33478"]
failures = 0


def check(what, ok, detail=""):
    global failures
    print(("ok    " if ok else "FAIL  ") + what + (f" — {detail}" if detail and not ok else ""))
    failures += 0 if ok else 1


def harness(*args, timeout=60):
    out = tempfile.mkdtemp()
    # On a real iPhone the harness listens on every address (run_device.sh: --listen 0.0.0.0).
    r = subprocess.run([sys.executable, "harness.py", "--out", out, "--listen", "0.0.0.0", *PORTS, *args], cwd=HOST,
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


# The harness waits, and says so.
code, text = harness("--wait-app", "32")
waits = [line for line in text.splitlines() if line.startswith("waiting for the app:")]
check("the harness says every 15 s that it waits for the app, and how long is left", len(waits) >= 2 and "left" in (waits or [""])[0],
      f"{len(waits)} such lines; output ends {text[-200:]!r}")

# A busy port: a clear word, no traceback. Held as the owner's leftover harness held it: listening on
# 0.0.0.0 (CI: a holder on another address let the harness bind on macOS — not the owner's case).
held = socket.socket()
held.bind(("0.0.0.0", 38310))
held.listen()
try:
    code, text = harness("--wait-app", "5")
    check("the harness on a busy port says so, without a traceback", "PORT IN USE" in text and "Traceback" not in text and code == 2,
          f"exit {code}; {text[-300:]!r}")
    pf = os.path.join(ROOT, "ports_free.py")
    if os.path.exists(pf):
        r = subprocess.run([sys.executable, pf, "38310", "38380", "33478/udp"], capture_output=True, text=True)
        check("ports_free.py names the busy port", r.returncode == 1 and "38310" in r.stderr, f"exit {r.returncode}: {r.stderr!r}")
    else:
        check("ports_free.py names the busy port", False, "no ports_free.py")
finally:
    held.close()
if os.path.exists(os.path.join(ROOT, "ports_free.py")):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "ports_free.py"), "38310", "38380", "33478/udp"], capture_output=True, text=True)
    check("ports_free.py passes free ports", r.returncode == 0, r.stderr)
    loop = socket.socket()
    loop.bind(("127.0.0.1", 38310))
    loop.listen()
    try:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "ports_free.py"), "38310"], capture_output=True, text=True)
        check("ports_free.py names a port held on 127.0.0.1 only", r.returncode == 1 and "38310" in r.stderr, f"exit {r.returncode}")
    finally:
        loop.close()

# The built app's identity.
ca = os.path.join(ROOT, "check_app.py")
if os.path.exists(ca):
    app = os.path.join(tempfile.mkdtemp(), "LumenMeasure.app")
    os.makedirs(app)
    with open(os.path.join(app, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.measure"}, f)
    wrong = subprocess.run([sys.executable, ca, app, "io.lumenbrowser.measure.TEAM"], capture_output=True, text=True)
    right = subprocess.run([sys.executable, ca, app, "io.lumenbrowser.measure"], capture_output=True, text=True)
    check("check_app.py refuses the owner's case (Info.plist …measure, launched …measure.<team>)",
          wrong.returncode == 1 and "NOT THE ONE" in wrong.stderr, wrong.stderr)
    check("check_app.py passes an app that is the one to launch", right.returncode == 0, right.stderr)
else:
    check("check_app.py refuses the owner's case", False, "no check_app.py")

# A capture that saw nothing makes the run fail, whatever else passed (the owner's second run: rvi0 got
# 0 packets, the detectors said INCONCLUSIVE, and the summary still read "16/16 core checks passed").
probe = r"""
import os, sys, tempfile, types
sys.path.insert(0, sys.argv[1])
import harness
tmp = tempfile.mkdtemp()
harness.ARGS = types.SimpleNamespace(out=tmp, run="t", brk="none", scenario="q1", capture="rvi0")
harness.CHECKS[:] = [{"name": "a", "status": "PASS", "detail": "", "core": True}]
cap = harness.Capture(os.path.join(tmp, "dns.txt"), "rvi0")
open(cap.path, "w").close()
open(cap.path + ".err", "w").write("0 packets captured\n0 packets received by filter\n0 packets dropped by kernel\n")
sys.exit(harness.finish(cap) if hasattr(harness, "finish") else 0)
"""
r = subprocess.run([sys.executable, "-c", probe, HOST], capture_output=True, text=True, cwd=HOST)
check("a run whose capture saw nothing is not a success (exit 1, CAPTURE SAW NOTHING)",
      r.returncode == 1 and "CAPTURE SAW NOTHING" in r.stdout and "'capture'" in r.stdout, f"exit {r.returncode}: {r.stdout[-300:]!r} {r.stderr[-200:]!r}")

# The first look, before the build: blind, or the VPN (the owner's own lines), stops the run.
cl = os.path.join(ROOT, "capture_look.py")
OWNER_VPN = ("1794152481.473011 IP 198.18.0.1.54420 > 198.18.0.2.53: 11395+ Type65? p-c-1dok9s.lumentest. (38)\n"
             "1794152506.237164 IP 198.18.0.1.49190 > 192.0.2.10.28380: Flags [SEW], seq 4015973822, win 65535, length 0\n")
CLEAN = "18:00:00.500000 IP 192.168.1.23.5353 > 224.0.0.251.5353: 0 PTR (QM)? _companion-link._tcp.local. (45)\n"
if os.path.exists(cl):
    looks = {}
    for name, body in (("blind", "tcpdump: listening on rvi1\n"), ("vpn", OWNER_VPN), ("clean", CLEAN)):
        path = os.path.join(tempfile.mkdtemp(), name + ".txt")
        open(path, "w").write(body)
        looks[name] = subprocess.run([sys.executable, cl, "judge", path], capture_output=True, text=True)
    check("the first look stops on a recording that sees nothing (exit 1)", looks["blind"].returncode == 1, looks["blind"].stdout)
    check("the first look stops on the owner's VPN (fake IP 198.18.0.1, exit 2)", looks["vpn"].returncode == 2, looks["vpn"].stdout)
    check("the first look lets a clean recording through", looks["clean"].returncode == 0, looks["clean"].stdout)
else:
    check("the first look stops on a recording that sees nothing, or on the VPN", False, "no capture_look.py")
script = open(os.path.join(ROOT, "run_device.sh")).read()
look_at, build_at = script.find('capture_look.py" look'), script.find("xcodebuild")
check("run_device.sh looks at the recording before the build", 0 <= look_at < build_at, f"look at {look_at}, build at {build_at}")

# The summary says what was not measured, beside the count.
probe2 = r"""
import os, sys, tempfile, types
sys.path.insert(0, sys.argv[1])
import harness
tmp = tempfile.mkdtemp()
harness.ARGS = types.SimpleNamespace(out=tmp, run="t", brk="none", scenario="q1", capture="")
harness.CHECKS[:] = [{"name": "a", "status": "PASS", "detail": "", "core": True},
                     {"name": "q1.dns", "status": "INCONCLUSIVE", "detail": "", "core": False}]
cap = harness.Capture(os.path.join(tmp, "dns.txt"), "")
sys.exit(harness.finish(cap) if hasattr(harness, "finish") else 0)
"""
r = subprocess.run([sys.executable, "-c", probe2, HOST], capture_output=True, text=True, cwd=HOST)
check("the summary names what it did not measure (NOT MEASURED: q1.dns)",
      "NOT MEASURED" in r.stdout and "q1.dns" in r.stdout.split("SUMMARY")[-1], f"{r.stdout[-300:]!r} {r.stderr[-200:]!r}")

print(f"{failures} failed")
sys.exit(1 if failures else 0)
