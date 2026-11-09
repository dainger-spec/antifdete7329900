#!/usr/bin/env python3
"""capture_look.py on the owner's cases, and the old run-device.sh's capture summary beside it.

    python3 ios/scripts/test_capture_look.py

The old summary printed "none" under both questions whatever the recording held: on a recording that
saw nothing (the owner's second run, rvi0: 0 packets) that reads as clean. Reproduced here (red), and
capture_look.py says NOT MEASURED instead (green).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capture_look import interface_for, judge, summarize  # noqa: E402

failures = 0


def check(what, ok, detail=""):
    global failures
    print(("ok    " if ok else "FAIL  ") + what + (f" — {detail}" if detail and not ok else ""))
    failures += 0 if ok else 1


def old_summary(text):
    """The old run-device.sh: grep the DNS lines for ipify, the SYNs to ipify addresses; "none" otherwise."""
    dns = [l for l in text.splitlines() if " 53" in l or ".53:" in l]
    dns = [l for l in dns if "ipify" in l.lower()]
    return ("none" if not dns else "seen", "none")


# tcpdump -n lines as rvi gives them (addresses replaced by documentation ranges where they were the owner's).
WIFI = "192.168.1.23"
LINES = {
    "own_q": f"18:01:02.100000 IP {WIFI}.50001 > 192.168.1.1.53: 4101+ A? ipv4.icanhazip.com. (36)",
    "own_a": f"18:01:02.130000 IP 192.168.1.1.53 > {WIFI}.50001: 4101 2/0/0 A 104.16.184.241, A 104.16.185.241 (68)",
    "own_syn": f"18:01:02.150000 IP {WIFI}.50002 > 104.16.184.241.80: Flags [S], seq 1, win 65535, length 0",
    "proxy_syn": f"18:01:03.000000 IP {WIFI}.50003 > 203.0.113.9.1080: Flags [S], seq 1, win 65535, length 0",
    "proxy_data": f"18:01:03.100000 IP {WIFI}.50003 > 203.0.113.9.1080: Flags [P.], seq 1:20, ack 1, length 19",
    "page_q": f"18:01:04.000000 IP {WIFI}.50004 > 192.168.1.1.53: 4102+ [1au] AAAA? api64.ipify.org. (44)",
    "page_a": f"18:01:04.020000 IP 192.168.1.1.53 > {WIFI}.50004: 4102 1/0/1 AAAA 2001:db8::6810:1 (72)",
    "page_syn6": "18:01:04.040000 IP6 2001:db8:1::23.50005 > 2001:db8::6810:1.443: Flags [S], seq 1, win 65535, length 0",
    "page_syn_cached": f"18:01:05.000000 IP {WIFI}.50006 > 104.26.12.205.443: Flags [S], seq 1, win 65535, length 0",
    "vpn": "18:00:00.000000 IP 198.18.0.1.50000 > 198.18.0.2.53: 77+ A? example.com. (29)",
    "plain": f"18:00:00.500000 IP {WIFI}.5353 > 224.0.0.251.5353: 0 PTR (QM)? _companion-link._tcp.local. (45)",
    "broadcast": "18:00:00.600000 IP 0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request, length 300",
}


def text(*names):
    return "\n".join(LINES[n] for n in names) + "\n"


# The owner's own capture (q1, 8 November, rvi0 through the harness: tcpdump -tt), five lines as they
# were, the Mac's address replaced: epoch time, HTTPS asked as "Type65?", a SYN flagged [SEW], the VPN.
OWNER = """1794152481.473011 IP 198.18.0.1.54420 > 198.18.0.2.53: 11395+ Type65? p-c-1dok9s.lumentest. (38)
1794152481.473080 IP 198.18.0.2.53 > 198.18.0.1.54420: 11395 0/0/0 (38)
1794152481.473100 IP 198.18.0.1.61098 > 198.18.0.2.53: 11020+ A? p-c-1dok9s.lumentest. (38)
1794152481.473136 IP 198.18.0.2.53 > 198.18.0.1.61098: 11020 1/0/0 A 240.0.0.47 (54)
1794152506.237164 IP 198.18.0.1.49190 > 192.0.2.10.28380: Flags [SEW], seq 4015973822, win 65535, options [mss 1460,nop,wscale 6,nop,nop,TS val 2249624330 ecr 0,sackOK,eol], length 0
"""

# The first look, before the run.
code, said = judge(OWNER)
check("first look on the owner's capture: their VPN is a stop (exit 2), its lines are packets", code == 2, said)
check("first look: nothing seen is a stop (exit 1)", judge("")[0] == 1)
check("first look: tcpdump's own messages are not packets",
      judge("tcpdump: listening on rvi0, link-type RAW (Raw IP), snapshot length 524288 bytes\n0 packets captured\n")[0] == 1)
code, said = judge(text("vpn", "plain"))
check("first look: the owner's VPN (fake IP 198.18.0.1) is a stop (exit 2)", code == 2 and "198.18.0.1" in said, said)
check("first look: the iPhone's own packets, no VPN: go (exit 0)", judge(text("plain", "own_q", "broadcast"))[0] == 0,
      judge(text("plain", "own_q", "broadcast"))[1])

# The interface rvictl made for this iPhone (not rvi0 taken for granted).
listed = ("\nCould not get list of devices\nCurrent Active Devices:\n\n"
          "\t[1] 00008110-000A1B2C3D4E5F6A with interface rvi0\n\t[2] 00008120-0011223344556677 with interface rvi1\n")
check("rvictl -l: the interface of this iPhone", interface_for(listed, "00008120-0011223344556677") == "rvi1")
check("rvictl -l: none for an iPhone it does not list", interface_for(listed, "00008130-0000000000000000") == "")
# The owner's macOS (9 November): `rvictl -l` lists the iPhone "with interface (null)" while rvi0 is
# there and records (ifconfig rvi0, tcpdump). The old rule read the interface from that list only.
UDID = "00008120-0011223344556677"
null_listed = f"\nCould not get list of devices\nCurrent Active Devices:\n\n\t[1] {UDID} with interface (null)\n"
old_rule = lambda listed, udid: next((m.group(0) for line in listed.splitlines() if udid.lower() in line.lower()
                                      for m in [re.search(r"\brvi\d+\b", line)] if m), "")
check("rvictl -l (null): the old rule finds no interface and the run stops — the bug, reproduced",
      old_rule(null_listed, UDID) == "" and old_rule(listed, UDID) == "rvi1")
check("rvictl -l (null): the one rvi interface the Mac has (ifconfig rvi0) is taken",
      interface_for(null_listed, UDID, "", ["rvi0"]) == "rvi0")
check("rvictl -l (null): what rvictl -s said comes first",
      interface_for(null_listed, UDID, f"Starting device {UDID} [SUCCEEDED] with interface rvi2\n", ["rvi0", "rvi2"]) == "rvi2")
check("rvictl -l (null) and several rvi interfaces: no guess", interface_for(null_listed, UDID, "", ["rvi0", "rvi1"]) == "")
check("an iPhone neither listed nor started: not another one's rvi0",
      interface_for(null_listed, "00008130-0000000000000000", "", ["rvi0"]) == "")
check("rvictl -l naming the interface still wins over ifconfig", interface_for(listed, UDID, "", ["rvi0"]) == "rvi1")

# q4's summary after the run.
check("old summary: a recording that saw nothing reads as clean (\"none\", \"none\") — the bug, reproduced",
      old_summary("") == ("none", "none"))
code, out = summarize(OWNER.replace("p-c-1dok9s.lumentest", "api.ipify.org").replace("240.0.0.47", "192.0.2.10"))
check("summary on the owner's line format: a Type65 question for ipify and a [SEW] SYN to its answer: LEAK",
      code == 1 and "2 DNS questions, 1 connections" in out[-1], "\n".join(out))
code, out = summarize("")
check("summary: a recording that saw nothing is NOT MEASURED (exit 2), not clean",
      code == 2 and "CAPTURE SAW NOTHING" in out[-1], out[-1])
code, out = summarize(text("own_q", "own_a", "own_syn", "proxy_syn", "proxy_data"))
check("summary: the control seen, ipify not: NO LEAK SEEN (exit 0)", code == 0 and "NO LEAK SEEN" in out[-1], "\n".join(out))
code, out = summarize(text("own_q", "own_a", "own_syn", "page_q", "page_a", "page_syn6"))
check("summary: a DNS question for ipify and a connection to its answer: LEAK (exit 1)",
      code == 1 and "1 DNS questions, 1 connections" in out[-1], "\n".join(out))
code, out = summarize(text("own_q", "own_a", "own_syn", "page_syn_cached"), [("api.ipify.org", "104.26.12.205")])
check("summary: a connection to an ipify address this Mac resolved (no DNS seen): LEAK",
      code == 1 and "0 DNS questions, 1 connections" in out[-1], "\n".join(out))
code, out = summarize(text("own_syn", "proxy_syn"), [("ipv4.icanhazip.com", "104.16.184.241")])
check("summary: no DNS question even for the control (encrypted DNS): NOT MEASURED, says DNS",
      code == 2 and "DNS" in out[-1], out[-1])
code, out = summarize(text("plain", "proxy_syn", "proxy_data"))
check("summary: packets but no control at all: NOT MEASURED", code == 2 and "NOT MEASURED" in out[-1], out[-1])

print(f"{failures} failed")
sys.exit(1 if failures else 0)
