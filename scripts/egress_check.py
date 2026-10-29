#!/usr/bin/env python3
"""Did anything go around a profile's proxy while the self-test's Safari-chrome check ran?

    sudo tcpdump -i pktap,all -k NP -n -tt -l 'not host 127.0.0.1 and not host ::1' > capture.txt &
    PrivacyBrowser --self-test | tee selftest.txt
    python3 scripts/egress_check.py --capture capture.txt --selftest-log selftest.txt

Two checks of the self-test open a window (`INFO egress-window begin/end`) and name a run id
(`INFO egress-token`): the proxy checker's (`proxyChecker`: every listener of the self-test proxy
probed step by step, checks through each to a geolocation service whose name carries the run id,
and a profile started with a proxy that never answers), in which this process talks to the proxy on
loopback and to nothing else; and the Safari-chrome one.

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
  its behalf by another process, to anything but loopback. A resolver's answer (from port 53) is
  not a packet the app sent — the question is, and a question asked in a window fails — so an
  answer that comes in a window to a question asked before it is listed, not failed on (measured:
  the NXDOMAIN for the proxy checker's control arrived 0.1 s after its window opened).

During the check, packets of Safari's own services and of the daemons a profile's process could ask
to fetch for it (search suggestions, Safe Browsing, Safari Suggestions, background URL sessions,
CloudKit, Web Push) fail too, whether they are the packet's process or the one it was sent for
(`eproc`: a DNS query mDNSResponder makes for Safari's service is that service's): nothing here
runs the real Safari, so they can only be the profile's — unless the service was already running
before the profile's first process started (a lower pid): then it was not started for the profile,
and its traffic (Safe Browsing's periodic update) cannot be told from the system's; it is listed.
Packets of other processes are listed,
never failed on. Any DNS question for a name under leak.example.com fails, whenever it is asked —
those names are the leak pages', and through the proxy they are never resolved here — except the
controls'.

A control (`INFO egress-control <name>`) is something the self-test makes this Mac do on purpose,
outside any proxy, so that the capture must show it: the TLS check's `pbaiacontrol`, a certificate
whose intermediate the system's trust service fetches, from a profile without a proxy; and the
proxy checker's `pbinvalid…`, a proxy host name under selftest.invalid that this Mac's resolver
is asked for (the proxy checker's geolocation service is a name under selftest.invalid too). Seen,
the capture is known to see such packets, and their absence where a proxy should have been used
means something; not seen, that part is inconclusive, and said so.

A capture that could not be made (no pktap, no sudo) makes the result inconclusive: a warning,
exit code 0.
"""
import argparse
import ipaddress
import re
import sys

# Services that fetch for whoever asks: in the check's window, theirs can only be the profile's.
# Process names in the capture are cut to 16 characters ("com.apple.Safari" is any of Safari's
# XPC services). Measured: the hosted chrome woke passd and translationd, and one of Safari's
# services sent QUIC to Apple, while the profile ran.
SERVICES = ("SearchHelper", "SafeBrowsing", "parsecd", "nsurlsessiond", "cloudd", "webpushd", "Safari",
            "passd", "translationd")
LEAK_DOMAIN = "leak.example.com"
# "... 12345+ A? fetch-abc.leak.example.com. (46)", "... 0 AAAA (QM)? lan-abc.local. (30)"
QUESTION = re.compile(r"\b(?:A|AAAA|HTTPS|SVCB|ANY|CNAME|TXT|PTR)(?: \(Q[MU]\))?\? (\S+?)\.? ")
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
        # From port 53: a resolver's answer ("192.168.64.1.53 > 192.168.64.12.58738: 52290 NXDomain").
        "dns_answer": bool(flow) and flow.group(1).endswith((".53", ".domain")),
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
    controls = re.findall(r"INFO egress-control (\w+)", log)
    begins = [float(t) for t in re.findall(r"INFO egress-window begin ([\d.]+)", log)]
    ends = [float(t) for t in re.findall(r"INFO egress-window end ([\d.]+)", log)]
    pids = {int(p) for p in re.findall(r"INFO egress-pid (\d+)", log)}
    if not tokens or not begins:
        print("::warning::egress check: no check of the self-test opened an egress window (no egress-token); nothing to look at")
        return 0
    # Each window ends at the first end after its begin: a check that stopped before printing its
    # end leaves its window open to the end of the run, never borrows another check's end.
    windows = [(b, min((e for e in ends if e >= b), default=float("inf"))) for b in begins]

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

    # A service that was running before the profile's first process started was not started for
    # it; its traffic cannot be told apart from the system's own (Safe Browsing's periodic update),
    # and is listed rather than failed on. One started during the check is the profile's.
    first_profile_pid = min(pids) if pids else None

    def service(owner):
        if owner is None or not any(name in owner[0] for name in SERVICES):
            return False
        return first_profile_pid is None or owner[1] >= first_profile_pid

    failures, others, seen_controls = [], {}, {}
    for packet in packets:
        line = packet["line"]
        lowered = line.lower()
        question = QUESTION.search(line)
        name = question.group(1).lower() if question else ""
        control = next((c for c in controls if c in lowered), None)
        if control:
            owners = [f"{kind} {owner[0]}" for kind, owner in (("proc", packet["proc"]), ("eproc", packet["eproc"])) if owner]
            seen_controls.setdefault(control, []).append(", ".join(owners) or "no process")
            continue
        if any(packet["dst"] is not None and packet["dst"].version == net.version and packet["dst"] in net
               for net in DOCUMENTATION):
            failures.append(("to a documentation address (only the leak page asks for those)", line))
        elif any(token in lowered for token in tokens):
            failures.append(("carries a run id or a canary (a name resolved, or a fetch made, on this Mac rather than through the proxy)", line))
        elif name.endswith(LEAK_DOMAIN):
            failures.append(("a DNS question for a leak page's name (resolved on this Mac, not by the proxy)", line))
        elif in_window(packet) and packet["dns_answer"]:
            # An answer is not a packet the app sent: the question is what counts, and a question
            # asked in the window fails above (its name) or below (its process). An answer that
            # comes in the window to a question asked before it — the proxy checker's control,
            # asked just before its window opens — is listed.
            others.setdefault("DNS answers (to questions asked before the window)", []).append(line)
        elif in_window(packet) and (ours(packet["proc"]) or ours(packet["eproc"])):
            if packet["dst"] is None or not packet["dst"].is_loopback:
                failures.append(("a PrivacyBrowser process (or one acting for it) reached past the proxy", line))
        elif in_window(packet) and (service(packet["proc"]) or service(packet["eproc"])):
            who = packet["proc"][0] if service(packet["proc"]) else f"{packet['eproc'][0]} (through {packet['proc'][0] if packet['proc'] else '?'})"
            failures.append((f"{who} fetched for someone while the profile ran", line))
        elif in_window(packet) and packet["proc"]:
            others.setdefault(packet["proc"][0], []).append(line)

    for control in controls:
        if control in seen_controls:
            print(f"egress check: control {control} seen {len(seen_controls[control])} times "
                  f"({sorted(set(seen_controls[control]))[:4]}): the capture sees such packets")
        else:
            print(f"::warning::egress check: control {control} was never seen — this macOS did not send it, or the "
                  f"capture cannot see it; the matching check where a proxy is used is inconclusive")

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
