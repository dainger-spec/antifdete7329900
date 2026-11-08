#!/usr/bin/env python3
"""The real-iPhone tooling's own checks, the ones that need no Mac (device-tools.yml runs them).

    python3 ios-measure/test_tools.py <an ios-measure directory>

Run on this tree it must pass; run on the tree before the owner's fixes (8 November) it must fail —
device-tools.yml does both, so each check is seen red before it is trusted:
  - the harness, while it waits for the app, says so every 15 s with the time left (before: silent);
  - the harness on a busy port says which and what to do, without a traceback (before: a traceback,
    after the build, the install and sudo);
  - ports_free.py names a busy port before anything slow, and passes free ones (before: none);
  - check_app.py refuses a built app whose bundle id is not the one to launch (before: none).
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

print(f"{failures} failed")
sys.exit(1 if failures else 0)
