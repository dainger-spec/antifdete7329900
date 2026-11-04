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

The guard reads whom a flow is for from the kernel's table of sockets as well (SocketTable; the
owner's Mac, 4 November: the filter named WebKit's network process, the capture `eproc` the
probe). While the probe runs, `Lumen --socket-owners 203.0.113.1` reads that table with the
guard's own code — as root, as the guard's extension runs: macOS 27.0.1 lists to a process that is
not root only its own sockets (claude/measure-guard-link 8cccd7b; macOS 26.6.2 lists them all to
anyone); every captured packet's socket (by its source port) must be in it, used by the
packet's proc and counted for its eproc. `--table-ignores-delegation` reads the table as if no
socket were delegated (its user only): the control, which must fail.
"""
import argparse
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress_check  # noqa: E402

STUN_ADDRESS = "203.0.113.1"  # GuardProof.stunAddress


def source_port(packet):
    """The packet's source port, from tcpdump's 'IP a.b.c.d.PORT > …'."""
    match = re.search(r"\bIP6? (\S+) > ", packet["line"])
    port = re.search(r"[.:](\d+)$", match.group(1)) if match else None
    return int(port.group(1)) if port else None


KERNEL_SOCKET = re.compile(r"KERNEL-SOCKET (\w+) local=(\d+) remote=\S+ last=(-?\d+) effective=(-?\d+) delegated=([01]) "
                           r"userland=([01]) counted=(-?\d+)")


def judge_table(packets, table, ignore_delegation):
    """(passed, lines): each packet's socket in the kernel's table as the app read it — used by the
    packet's proc and counted for its eproc."""
    lines = []
    if not table:
        return False, ["the app read no socket to the probe's STUN address from the kernel's table: nothing compared"]
    passed = True
    for packet in packets:
        port = source_port(packet)
        entry = table.get(port)
        if entry is None:
            passed = False
            lines.append(f"TABLE-WRONG port {port}: not in the table the app read ({sorted(table)})")
            continue
        last, effective, kind, counted = entry
        if ignore_delegation:
            counted = last
        proc, eproc = packet["proc"], packet["eproc"]
        same = proc is not None and proc[1] == last and eproc is not None and eproc[1] == counted
        passed = passed and same
        lines.append(f"{'TABLE-OK' if same else 'TABLE-WRONG'} port {port}: the table says used by {last}, "
                     f"counted for {counted} ({kind}, effective pid {effective}); the capture proc {proc}, eproc {eproc}")
    return passed, lines


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
    parser.add_argument("--table-ignores-delegation", action="store_true",
                        help="the table's control: read it as if no socket were delegated (must fail)")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    # The probe stands in for a profile's process, started as one is (ProfileExecutable.swift).
    binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "LumenProfile")
    if not os.path.exists(binary):
        binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "Lumen")
    app_binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "Lumen")
    table = {}
    table_said = []
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
        probe.stdin.close()
        rest_lines = []
        reader = threading.Thread(target=lambda: rest_lines.extend(probe.stdout.readlines()), daemon=True)
        reader.start()
        # The kernel's table, read by the app's own code while the probe runs: its STUN sockets, by
        # local port, the first reading of each kept.
        started = time.time()
        while probe.poll() is None and time.time() - started < 60:
            owners = subprocess.run(["sudo", "-n", app_binary, "--socket-owners", STUN_ADDRESS], capture_output=True, text=True, timeout=20)
            for line in owners.stdout.splitlines():
                match_socket = KERNEL_SOCKET.search(line)
                if line.startswith("KERNEL-TABLE") and line not in table_said:
                    table_said.append(line)
                if match_socket and match_socket.group(1) == "udp":
                    port = int(match_socket.group(2))
                    reading = (int(match_socket.group(3)), int(match_socket.group(4)),
                               "delegated" if match_socket.group(5) == "1" else "user-space stack" if match_socket.group(6) == "1" else "own",
                               int(match_socket.group(7)))
                    if port not in table:
                        table[port] = reading
                        table_said.append(f"+{time.time() - started:.1f} s port {port}: first read {reading}")
                    elif reading != table[port] and f"port {port}: then {reading}" not in " ".join(table_said):
                        # Compared is the first reading, as the guard reads a flow once when it comes.
                        table_said.append(f"+{time.time() - started:.1f} s port {port}: then {reading}")
            time.sleep(0.2)
        if probe.poll() is None:
            probe.kill()
        probe.wait()
        reader.join(timeout=10)
        rest = "".join(rest_lines)
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
    for line in table_said:
        print(f"  {line}")
    table_passed, table_lines = judge_table(packets, table, args.table_ignores_delegation)
    for line in table_lines:
        print(f"  {line}")
    passed = passed and table_passed
    summary = (f"GUARD-PROBE-CHECK {'PASSED' if passed else 'FAILED'}: {len(packets)} packet(s) to {STUN_ADDRESS}, "
               f"the probe pid {probe_pid}" + (f", compared with {expected}" if expected != probe_pid else "")
               + f"; the kernel's table as the app read it {'agrees' if table_passed else 'does NOT agree'} with the capture"
               + (" (read as if nothing were delegated: the control)" if args.table_ignores_delegation else ""))
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(f"### The network guard's probe\n{summary}\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
