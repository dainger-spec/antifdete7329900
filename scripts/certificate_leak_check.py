#!/usr/bin/env python3
"""Did this Mac fetch for a certificate outside a profile's proxy? The one check of CI's macOS 27
job that fails the build: everything else that job finds is reported, never failed on.

    python3 scripts/certificate_leak_check.py --capture build/egress27/capture.txt \\
        --selftest-log build/egress27/selftest.txt --app build/unsandboxed/PrivacyBrowser.app \\
        --out build/egress27/certificate-leak

The self-test's certificate check (`certificatesWithoutFetching`) loads, in a profile with a proxy,
the self-test proxy's certificate: its chain is complete only for a client that fetches the missing
intermediate from the address it names (`pbaiacanary`), and it names a revocation responder
(`pbocspcanary`). On macOS 27, from SDK 15.0 on, WebKit had this Mac fetch it outside the proxy
(docs/ISOLATION_AND_LIMITATIONS.md); one night's change made every build do so (run 458), and the
job, which failed nothing, let it through. Its control is the same kind of certificate (`pbaiacontrol`)
in a profile without a proxy, for which macOS 27 does fetch: the capture has to see that one, or the
absence of the canary says nothing. In the capture of the whole self-test:

  * any packet naming a canary — a leak: fails;
  * no canary, the control asked for: clean;
  * no canary and no control (once in 21 runs, run 451), no capture, or no certificate check in the
    self-test's output: that run cannot tell. The certificate check then runs again, alone, under a
    capture of its own, with certificates naming addresses no earlier check asked for
    (scripts/aia_variants.py's variant, the app as built; at most twice): clean only with its
    control asked for and no canary. Anything else fails.
"""
import argparse
import os
import re
import subprocess
import sys
import time

import aia_variants

TITLE = "macOS 27 - a certificate fetched outside the proxy"
CANARIES = ("pbaiacanary", "pbocspcanary")
CONTROL = "pbaiacontrol"
TIME = re.compile(r"^\d+\.\d+ ")


def say(level, text):
    print(f"CERT-LEAK {text}", flush=True)
    if level:
        print(f"::{level} title={TITLE}::{text[:900]}", flush=True)


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except OSError:
        return None


def judge(lines, canaries, control):
    """'leak' with the lines that name a canary, 'clean', or 'cannot tell' with why."""
    if lines is None:
        return "cannot tell", ["no capture"]
    packets = [line for line in lines if TIME.match(line)]
    if not packets:
        return "cannot tell", ["the capture holds no packets"]
    leaks = [line for line in packets if any(canary in line.lower() for canary in canaries)]
    if leaks:
        return "leak", leaks
    if any(control in line.lower() and "?" in line for line in packets):
        return "clean", []
    return "cannot tell", [f"the control ({control}) was never asked for: this Mac did not fetch for it, or the capture cannot see it"]


def run_alone(app, out, attempt):
    """The certificate check alone, under a capture of its own, with names of its own."""
    capture_path = os.path.join(out, f"capture-{attempt}.txt")
    capture = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                "not host 127.0.0.1 and not host ::1"],
                               stdout=open(capture_path, "w"), stderr=open(os.path.join(out, f"tcpdump-{attempt}.err"), "w"))
    time.sleep(2)
    try:
        tag, _, _, output = aia_variants.run_variant(attempt, app, [], out, TITLE)
    finally:
        subprocess.run(["sudo", "-n", "kill", "-INT", str(capture.pid)], capture_output=True)
        try:
            capture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            capture.kill()
    with open(os.path.join(out, f"selftest-{attempt}.txt"), "w") as handle:
        handle.write(output)
    for line in output.splitlines():
        if line.startswith(("PASS certificates", "FAIL certificates")):
            say(None, f"  attempt {attempt}: {line[:300]}")
    return judge(read_lines(capture_path), [canary + tag for canary in CANARIES], CONTROL + tag)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True, help="the capture of the whole self-test")
    parser.add_argument("--selftest-log", required=True)
    parser.add_argument("--app", required=True, help="the app the self-test ran, to run the certificate check again")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    log = read_lines(args.selftest_log) or []
    if not any(line.startswith("INFO egress-token pbaiacanary") for line in log):
        verdict, why = "cannot tell", ["the self-test's output has no certificate check"]
    else:
        verdict, why = judge(read_lines(args.capture), CANARIES, CONTROL)
    if verdict == "leak":
        say("error", f"this Mac asked for a certificate's address outside a profile's proxy, {len(why)} packet(s) in the self-test's capture")
        for line in why[:20]:
            say(None, f"LEAK {line[:300]}")
        return 1
    if verdict == "clean":
        say("notice", "clean: no canary in the self-test's capture, and its control was asked for")
        return 0

    say("warning", f"the self-test's run cannot tell ({'; '.join(why)}): the certificate check runs again alone")
    for attempt in (1, 2):
        if not os.path.exists(os.path.join(args.app, aia_variants.BINARY)):
            say("error", f"cannot tell, and no app to run the certificate check again ({args.app})")
            return 1
        verdict, why = run_alone(args.app, out, attempt)
        if verdict == "leak":
            say("error", f"attempt {attempt}: this Mac asked for a certificate's address outside a profile's proxy")
            for line in why[:20]:
                say(None, f"LEAK {line[:300]}")
            return 1
        if verdict == "clean":
            say("notice", f"clean on attempt {attempt}: no canary, and its control was asked for")
            return 0
        say("warning", f"attempt {attempt} cannot tell either: {'; '.join(why)}")
    say("error", "cannot tell whether this Mac fetches for a certificate outside a profile's proxy: failed, as a leak would")
    return 1


if __name__ == "__main__":
    sys.exit(main())
