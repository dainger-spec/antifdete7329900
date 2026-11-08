#!/usr/bin/env python3
"""The recording of the iPhone's own packets (rvictl): made, looked at before the run, judged after.
The same file serves ios/scripts/run-device.sh (q4, the app) and ios-measure/run_device.sh (q1–q3).

The owner's second iPhone run (8 November): the capture on rvi0 got 0 packets for the whole run, and
the run still read as passed. The first: the iPhone's VPN client (fake IP, 198.18.0.1) was in the
chain. So, before anything is measured, the capture must be seen to work and the VPN to be off; and
afterwards a recording that saw nothing, or could not see what it looks for, gives no verdict.

    capture_look.py start <UDID>            (root) rvictl for this iPhone; prints the rvi interface
    capture_look.py look <rviN> [seconds]   (root) a first look: exit 0 the iPhone's packets are
                                            seen and no VPN; 1 nothing seen; 2 the VPN is on
    capture_look.py judge <file>            the first look's verdict on saved tcpdump -n text
    capture_look.py summary <pcap>          q4: did the iPhone reach the echo service (ipify) around
                                            its proxy? Exit 0 no leak seen, 1 leak, 2 not measured
    capture_look.py summary-text <file>     the same on saved `tcpdump -n -r pcap` text
"""
import ipaddress
import re
import subprocess
import sys

# A VPN client in "fake IP" mode answers every name with an address from these and carries the
# traffic itself (the owner's: the iPhone at 198.18.0.1, its DNS server 198.18.0.2, a name answered
# with 240.0.0.47).
FAKE_IP = [ipaddress.ip_network("198.18.0.0/15"), ipaddress.ip_network("240.0.0.0/4")]
# The page in the probe asks these, through the session's proxy only.
PAGE_ECHO = ("api.ipify.org", "api64.ipify.org")
# The app asks these itself, directly, on purpose: the control — a capture that does not see them
# cannot see a leak either.
OWN_ECHO = ("ipv4.icanhazip.com", "ipv6.icanhazip.com")

# A packet line: "18:01:02.100000 IP …" (tcpdump -n), or "1794152481.473011 IP …" (-tt, the harness's).
PACKET = re.compile(r"^(?:\d\d:\d\d:\d\d\.\d+|\d{9,}\.\d+) ")
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d])")


def packets(text):
    return [line for line in text.splitlines() if PACKET.match(line)]


def fake_ip_addresses(lines):
    seen = set()
    for line in lines:
        for candidate in IPV4.findall(line):
            try:
                address = ipaddress.ip_address(candidate)
            except ValueError:
                continue
            if address != ipaddress.ip_address("255.255.255.255") and any(address in n for n in FAKE_IP):
                seen.add(candidate)
    return sorted(seen)


def judge(text, interface="the capture", seconds=0):
    """The first look: (exit code, what to say)."""
    lines = packets(text)
    vpn = fake_ip_addresses(lines)
    if not lines:
        return 1, (f"THE CAPTURE ON {interface} SEES NOTHING FROM THE iPHONE" + (f" in {seconds} s" if seconds else "") +
                   ": nothing would be measured. Unlock the iPhone and open any page on it during the look; "
                   "`rvictl -l` must list it. Unplug and plug the cable, then run again. (Without a cable: NO_CAPTURE=1.)")
    if vpn:
        return 2, (f"THE iPHONE'S VPN IS ON: its packets carry fake-IP addresses ({', '.join(vpn[:4])}). Turn the VPN "
                   "off (Settings › VPN, and in the VPN app itself, including any \"on demand\"), then run again.")
    return 0, f"the capture on {interface} sees the iPhone: {len(lines)} packets in a first look, no VPN addresses"


def start(udid):
    subprocess.run(["rvictl", "-x", udid], capture_output=True, text=True)
    made = subprocess.run(["rvictl", "-s", udid], capture_output=True, text=True)
    listed = subprocess.run(["rvictl", "-l"], capture_output=True, text=True).stdout
    interface = interface_for(listed, udid)
    if not interface:
        print(f"rvictl made no interface for {udid}: {(made.stdout + made.stderr).strip()!r}; rvictl -l: {listed.strip()!r}",
              file=sys.stderr)
        return 1
    print(interface)
    return 0


def interface_for(listed, udid):
    for line in listed.splitlines():
        if udid.lower() in line.lower():
            found = re.search(r"\brvi\d+\b", line)
            if found:
                return found.group(0)
    return ""


def look(interface, seconds):
    try:
        out = subprocess.run(["/usr/sbin/tcpdump", "-i", interface, "-n", "-l", "-c", "200"],
                             capture_output=True, text=True, timeout=seconds).stdout
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    code, said = judge(out, interface, seconds)
    print(said, file=sys.stderr if code else sys.stdout)
    return code


# ---- q4: the recording of the whole run ------------------------------------------------------

# "4101+ A? name. (36)", "11395+ Type65? name. (38)" (HTTPS, as the owner's capture shows it), "[1au]" with EDNS.
QUESTION = re.compile(r": (\d+)\+?(?: \[[^\]]*\])? (\w+)\? (\S+?)\.? \(")
ANSWER = re.compile(r"\.53 > \S+: (\d+)[^ ]* \d+/\d+/\d+ (.*)")
# A connection's first packet: "Flags [S]", or "[SEW]" with ECN (the owner's capture); never "[S.]".
SYN = re.compile(r"(IP6?) (\S+) > (\S+?): Flags \[S[EW]*\],")


def endpoint(text):
    """The address of a tcpdump endpoint: "104.26.12.205.443" or "2606:4700::6810:b8c4.443"."""
    return text.rsplit(".", 1)[0]


def summarize(text, resolved=()):
    """q4's capture verdict on `tcpdump -n -r` text: (exit code, lines). `resolved`: the echo names'
    addresses as this Mac resolves them, besides those the iPhone's own DNS answers show."""
    lines = packets(text)
    names = {}            # DNS id -> the name asked
    asked = []            # (name, line)
    addresses = {}        # address -> the echo name it answers for
    for line in lines:
        q = QUESTION.search(line)
        if q:
            names[q.group(1)] = q.group(3).lower()
            asked.append((q.group(3).lower(), line))
            continue
        a = ANSWER.search(line)
        if a and a.group(1) in names:
            for address in re.findall(r"\bA{1,4} ([0-9a-fA-F:.]+)", a.group(2)):
                addresses[address.rstrip(",")] = names[a.group(1)]
    for name, address in resolved:
        addresses.setdefault(address, name)
    syns = []
    for line in lines:
        s = SYN.search(line)
        if s:
            syns.append((endpoint(s.group(3)), line))

    def is_page(name):
        return any(name == n or name.endswith("." + n) for n in PAGE_ECHO)

    def is_own(name):
        return any(name == n or name.endswith("." + n) for n in OWN_ECHO)

    page_dns = [line for name, line in asked if is_page(name)]
    own_dns = [line for name, line in asked if is_own(name)]
    page_syn = [line for dst, line in syns if is_page(addresses.get(dst, ""))]
    own_syn = [line for dst, line in syns if is_own(addresses.get(dst, ""))]
    out = [f"recorded: {len(lines)} packets",
           f"control — the app's own direct questions to icanhazip, on purpose: DNS questions {len(own_dns)}, "
           f"connections {len(own_syn)}",
           "DNS questions for ipify from the iPhone:"] + (["  " + l for l in page_dns] or ["  none"]) + \
          ["connections from the iPhone to ipify addresses (SYN):"] + (["  " + l for l in page_syn] or ["  none"])
    if not lines:
        return 2, out + ["CAPTURE VERDICT: NOT MEASURED — CAPTURE SAW NOTHING (0 packets)"]
    if page_dns or page_syn:
        return 1, out + [f"CAPTURE VERDICT: LEAK — the iPhone reached ipify around its proxy "
                         f"({len(page_dns)} DNS questions, {len(page_syn)} connections)"]
    unseen = []
    if not own_dns:
        unseen.append("DNS (no question for icanhazip either: encrypted DNS, e.g. iCloud Private Relay, or a VPN)")
    if not own_syn:
        unseen.append("connections (none to icanhazip either)")
    if unseen:
        return 2, out + ["CAPTURE VERDICT: NOT MEASURED — the capture could not see the control: " + "; ".join(unseen)]
    return 0, out + ["CAPTURE VERDICT: NO LEAK SEEN — the control is seen, ipify is not"]


def resolve_here():
    pairs = []
    for name in PAGE_ECHO + OWN_ECHO:
        for kind in ("A", "AAAA"):
            try:
                out = subprocess.run(["dig", "+short", kind, name], capture_output=True, text=True, timeout=10).stdout
            except (OSError, subprocess.TimeoutExpired):
                continue
            for line in out.split():
                try:
                    ipaddress.ip_address(line)
                    pairs.append((name, line))
                except ValueError:
                    pass
    return pairs


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    command, rest = argv[1], argv[2:]
    if command == "start":
        return start(rest[0])
    if command == "look":
        return look(rest[0], int(rest[1]) if len(rest) > 1 else 30)
    if command == "judge":
        code, said = judge(open(rest[0]).read())
        print(said)
        return code
    if command in ("summary", "summary-text"):
        if command == "summary":
            text = subprocess.run(["tcpdump", "-n", "-r", rest[0]], capture_output=True, text=True).stdout
            resolved = resolve_here()
        else:
            text, resolved = open(rest[0]).read(), [tuple(p.split("=", 1)) for p in rest[1:]]
        code, lines = summarize(text, resolved)
        print("\n".join(lines))
        return code
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
