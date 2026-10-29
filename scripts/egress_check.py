#!/usr/bin/env python3
"""Did anything go around a profile's proxy while the self-test's Safari-chrome check ran?

    sudo tcpdump -i pktap,all -k NP -n -tt -l 'not host 127.0.0.1 and not host ::1' > capture.txt &
    PrivacyBrowser --self-test | tee selftest.txt
    python3 scripts/egress_check.py --capture capture.txt --selftest-log selftest.txt

The self-test's `safariChromeThroughTheProxy` runs a proxied profile in its own process, in
Safari's chrome, on the leak page of the self-test proxy (scripts/selftest_proxy.py `/pb-leak`):
requests of every kind a page can make, to addresses in the documentation ranges (192.0.2.0/24,
198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32) and to host names carrying the run's id. The
proxy is on the loopback interface and answers everything itself, connecting nowhere. So,
during that check, nothing at all should leave this machine on account of the profile, and the
capture — every packet that is not loopback, with the process each one belongs to (macOS's
pktap metadata: `proc name:pid`, and `eproc` for a process acting on another's behalf) — can say
so. It fails on:

* any packet to a documentation address, at any time: only the leak page asks for those, and
  through the proxy they never leave the loopback interface;
* any packet carrying the run's id — a DNS query for one of the leak page's host names means a
  name was resolved on this Mac instead of by the proxy;
* during the check (the self-test prints `INFO egress-window begin/end`), any packet of a
  `PrivacyBrowser` process (the profile's own, `INFO egress-pid`, or the self-test's), or made on
  its behalf by another process, to anything but loopback.

Packets of other processes are listed (a Safari service that this machine runs anyway is not the
profile's), never failed on. A capture that could not be made (no pktap, no sudo) makes the
result inconclusive: a warning, exit code 0.
"""
import argparse
import ipaddress
import re
import sys

DOCUMENTATION = [ipaddress.ip_network(n) for n in
                 ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]
# "1730000000.123456 (proc PrivacyBrowser:4242, eproc ..., svc BE, out) IP 10.0.0.5.51000 > 192.0.2.10.8080: ..."
META = re.compile(r"\(([^()]*)\)")
PROC = re.compile(r"(?<![e])proc ([^,():]+):(\d+)")
EPROC = re.compile(r"eproc ([^,():]+):(\d+)")
FLOW = re.compile(r"\bIP6? (\S+) > (\S+?):? ")
TIME = re.compile(r"^(\d+\.\d+)")


def address(endpoint: str):
    """'10.0.0.5.51000', '10.0.0.5' or '2001:db8::10.8080' (tcpdump -n) → the address alone."""
    for candidate in (endpoint, endpoint.rsplit(".", 1)[0]):
        try:
            return ipaddress.ip_address(candidate)
        except ValueError:
            continue
    return None


def parse(line: str):
    meta = META.search(line)
    fields = meta.group(1) if meta else ""
    proc = PROC.search(fields)
    eproc = EPROC.search(fields)
    flow = FLOW.search(line)
    time = TIME.search(line)
    return {
        "time": float(time.group(1)) if time else None,
        "proc": (proc.group(1), int(proc.group(2))) if proc else None,
        "eproc": (eproc.group(1), int(eproc.group(2))) if eproc else None,
        "src": address(flow.group(1)) if flow else None,
        "dst": address(flow.group(2)) if flow else None,
        "line": line.rstrip("\n"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True)
    parser.add_argument("--selftest-log", required=True)
    parser.add_argument("--tcpdump-errors", help="tcpdump's own standard error, shown when the capture is empty")
    args = parser.parse_args()

    log = open(args.selftest_log, encoding="utf-8", errors="replace").read()
    tokens = re.findall(r"INFO egress-token (\w+)", log)
    begins = [float(t) for t in re.findall(r"INFO egress-window begin ([\d.]+)", log)]
    ends = [float(t) for t in re.findall(r"INFO egress-window end ([\d.]+)", log)]
    pids = {int(p) for p in re.findall(r"INFO egress-pid (\d+)", log)}
    if not tokens or not begins:
        print("::warning::egress check: the self-test did not run its Safari-chrome check (no egress-token); nothing to look at")
        return 0
    windows = [(b, ends[i] if i < len(ends) else float("inf")) for i, b in enumerate(begins)]

    try:
        lines = open(args.capture, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as error:
        print(f"::warning::egress check inconclusive: no capture ({error})")
        return 0
    packets = [parse(line) for line in lines if TIME.search(line)]
    if not packets:
        errors = ""
        if args.tcpdump_errors:
            try:
                errors = open(args.tcpdump_errors, encoding="utf-8", errors="replace").read()[-2000:]
            except OSError:
                pass
        print(f"::warning::egress check inconclusive: the capture holds no packets. tcpdump said: {errors}")
        return 0
    with_meta = sum(1 for p in packets if p["proc"])
    print(f"egress check: {len(packets)} packets captured, {with_meta} with a process; run ids {tokens}; "
          f"windows {[(round(b, 1), round(e, 1)) for b, e in windows]}; profile processes {sorted(pids)}")
    print("first lines of the capture, for the format:")
    for line in lines[:5]:
        print("   ", line[:220])

    def in_window(packet):
        return packet["time"] is not None and any(b <= packet["time"] <= e for b, e in windows)

    def ours(owner):
        return owner is not None and (owner[1] in pids or owner[0].startswith("PrivacyBrowser"))

    failures, others = [], {}
    for packet in packets:
        line = packet["line"]
        if any(packet["dst"] is not None and packet["dst"].version == net.version and packet["dst"] in net
               for net in DOCUMENTATION):
            failures.append(("to a documentation address (only the leak page asks for those)", line))
        elif any(token in line.lower() for token in tokens):
            failures.append(("carries the run id (a name resolved on this Mac, not by the proxy)", line))
        elif in_window(packet) and (ours(packet["proc"]) or ours(packet["eproc"])):
            if packet["dst"] is None or not packet["dst"].is_loopback:
                failures.append(("a PrivacyBrowser process (or one acting for it) reached past the proxy", line))
        elif in_window(packet) and packet["proc"]:
            others.setdefault(packet["proc"][0], []).append(line)

    if others:
        print("other processes during the check (listed, not failed on):")
        for name, entries in sorted(others.items(), key=lambda item: -len(item[1])):
            print(f"  {name}: {len(entries)} packets, e.g. {entries[0][:200]}")
    if failures:
        print(f"::error::egress check: {len(failures)} packets went around the profile's proxy")
        for reason, line in failures[:60]:
            print(f"LEAK {reason}: {line[:300]}")
        return 1
    print("egress check: nothing went around the profile's proxy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
