#!/usr/bin/env python3
"""Whom macOS counts the network guard's probe for (docs/TUNNEL.md, "Attribution").

    python3 scripts/guard_probe_check.py --app build/unsandboxed/Lumen.app --out build/guard-probe

The network guard holds a profile by the process each new flow is counted for (a content filter's
"source application"), not by the process that opened it: WebRTC's sockets are opened by WebKit's
network process. `Lumen --guard-probe` (GuardProbe.swift) is the process the guard's check on a
Mac holds; here, where no guard can run, it runs inside a pktap capture of its STUN address
(TEST-NET-3, never routed on the Internet), and the capture shows for each packet the process that
sent it (proc) and the one the system counts it for (eproc).

Passes only if the probe's packets were sent by another process than the probe and every one of
them is counted for the probe's own pid: what the guard needs to hold a profile's WebRTC. Fails
(exit 1) when a packet is counted for any other process, or when no packet was captured at all
(the probe sent none, or the capture saw none: then nothing was shown). `--expect-pid N` replaces
the probe's pid in the comparison: the checker's own control (a pid that is not the probe's must
fail it).
"""
import argparse
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress_check  # noqa: E402

STUN_ADDRESS = "203.0.113.1"  # GuardProof.stunAddress


def judge(packets, probe_pid):
    """(passed, lines) for the captured packets of the probe, as dictionaries of egress_check.parse."""
    lines = []
    if not packets:
        return False, ["no packet to the probe's STUN address was captured: nothing is shown"]
    passed = True
    for packet in packets:
        proc, eproc = packet["proc"], packet["eproc"]
        sent_by_other = proc is not None and proc[1] != probe_pid
        counted_for_probe = eproc is not None and eproc[1] == probe_pid
        verdict = "OK" if sent_by_other and counted_for_probe else "WRONG"
        if verdict == "WRONG":
            passed = False
        lines.append(f"{verdict} sent by {proc}, counted for {eproc}: {packet['line'][:200]}")
    return passed, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--expect-pid", type=int, help="the checker's control: compare with this pid instead of the probe's")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "Lumen")
    capture_path = os.path.join(args.out, "capture.txt")
    with open(capture_path, "w") as capture, open(capture_path + ".err", "w") as errors:
        tcpdump = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                    f"host {STUN_ADDRESS}"], stdout=capture, stderr=errors)
        time.sleep(3)
        probe = subprocess.Popen([binary, "--guard-probe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
        first = probe.stdout.readline()
        match = re.match(r"GUARD-PROBE pid (\d+)", first)
        probe.stdin.write("go\n")
        probe.stdin.flush()
        try:
            rest, _ = probe.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            probe.kill()
            rest, _ = probe.communicate()
        time.sleep(2)
        subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], check=False)
        tcpdump.wait(timeout=20)
    print(first.rstrip())
    print(rest.rstrip())
    if not match:
        print("GUARD-PROBE-CHECK FAILED: the probe did not say its pid")
        return 1
    probe_pid = int(match.group(1))
    expected = args.expect_pid if args.expect_pid is not None else probe_pid
    with open(capture_path, errors="replace") as handle:
        packets = [p for p in (egress_check.parse(line) for line in handle) if p["dst"] is not None
                   and str(p["dst"]) == STUN_ADDRESS]
    passed, lines = judge(packets, expected)
    for line in lines:
        print(f"  {line}")
    summary = (f"GUARD-PROBE-CHECK {'PASSED' if passed else 'FAILED'}: {len(packets)} packet(s) to {STUN_ADDRESS}, "
               f"the probe pid {probe_pid}" + (f", compared with {expected}" if expected != probe_pid else ""))
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(f"### The network guard's probe\n{summary}\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
