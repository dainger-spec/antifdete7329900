#!/usr/bin/env python3
"""Measurement, on a branch only: a profile's WebRTC on the wire, for each kind of proxy.

    python3 scripts/measure/webrtc_udp.py --app build/unsandboxed/Lumen.app --out build/measure

The owner's question 1 (1 November), answered by traffic, not by reading code; and the part of
question 3 that a Mac without a network extension can answer: can a profile's UDP be told apart from
another's by the process it comes from, the way a NetworkExtension would have to?

Every scenario is its own `Lumen --capture-sites` run (the leak check's WebRTC page and its two-peer
data-channel page), inside one pktap capture of the whole Mac (`tcpdump -i pktap,all -k INP`), so
every packet names its interface, the process that sent it (`proc`) and, when that process acted
for another, the process it acted for (`eproc`). The proxies run on this Mac (scripts/leak_check.py's
ForwardingProxy, logging every command), and loopback is not captured: a packet of the app's
processes in the capture, outside lo0, left this Mac without going through a proxy.

  direct         no proxy, WebRTC "unrestricted"              the control: WebRTC's UDP must show
  http           HTTP CONNECT proxy, "unrestricted" stored
  http-default   HTTP CONNECT proxy, the default WebRTC setting
  socks          SOCKS5 proxy without UDP, "unrestricted" stored, no tunnel
  socks-udp      SOCKS5 proxy with UDP ASSOCIATE, "unrestricted" stored, no tunnel
  socks-default  SOCKS5 proxy with UDP ASSOCIATE, the default WebRTC setting
  socks-relay    SOCKS5 with UDP ASSOCIATE through the tunnel's relay code (the leak check's harness)
  two-direct     two app processes at once, a direct profile each: whose STUN packets are whose?

Writes <out>/report.json, <out>/capture.txt and a summary (stdout and the job's summary). A
measurement: it fails only when it measured nothing.
"""
import argparse
import collections
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import egress_check  # noqa: E402  (parse, QUESTION)
import leak_check  # noqa: E402  (ForwardingProxy, WEBRTC_SCRIPT, LOOP_SCRIPT, QUIC_SITE)

PAGES = [
    {"name": "webrtc", "url": leak_check.QUIC_SITE, "script": leak_check.WEBRTC_SCRIPT, "timeoutMs": 30000},
    {"name": "webrtc-loop", "url": leak_check.QUIC_SITE, "script": leak_check.LOOP_SCRIPT, "timeoutMs": 45000},
]
STUN_PORTS = {"3478", "19302"}


def app_process(owner):
    """The app's own processes and WebKit's (pktap keeps 15 characters of a name)."""
    return owner is not None and (owner[0].startswith("Lumen") or owner[0].startswith("com.apple.WebK"))


def start(app, out, name, profiles):
    spec_path = os.path.join(out, name + "-spec.json")
    with open(spec_path, "w") as handle:
        json.dump({"window": {"width": 1000, "height": 600}, "profiles": profiles, "pages": PAGES}, handle)
    results = os.path.join(out, name)
    os.makedirs(results, exist_ok=True)
    log = open(os.path.join(out, name + ".log"), "w")
    binary = os.path.join(app, "Contents", "MacOS", "Lumen")
    return subprocess.Popen([binary, "--capture-sites", spec_path, results], stdout=log, stderr=subprocess.STDOUT)


def page_results(out, name, profile):
    path = os.path.join(out, name, profile + ".json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def endpoint_port(line):
    """The destination port of a tcpdump -n line, as text ('19302'), or None."""
    flow = egress_check.FLOW.search(line)
    if not flow:
        return None
    destination = flow.group(2)
    return destination.rsplit(".", 1)[1] if "." in destination else None


def protocol(line):
    """tcp, icmp or udp: tcpdump decodes some UDP (DNS, QUIC) without saying UDP."""
    if "Flags [" in line:
        return "tcp"
    if "ICMP" in line:
        return "icmp"
    return "udp"


def interface(line):
    meta = egress_check.META.search(line)
    return meta.group(1).split(",")[0].strip() if meta else None


def wire(packets, begin, end):
    """The app's packets (sent by it, or for it) in [begin, end], outside loopback."""
    seen = []
    for packet in packets:
        if packet["time"] is None or not (begin <= packet["time"] <= end):
            continue
        if not (app_process(packet["proc"]) or app_process(packet["eproc"])):
            continue
        if interface(packet["line"]) == "lo0":
            continue
        seen.append(packet)
    udp = [p for p in seen if protocol(p["line"]) == "udp"]
    dns = [p for p in seen if endpoint_port(p["line"]) in ("53", "domain")]
    stun = [p for p in seen if endpoint_port(p["line"]) in STUN_PORTS]
    questions = sorted({q for p in dns for q in egress_check.QUESTION.findall(p["line"])})
    by_destination = collections.Counter()
    owners = collections.Counter()
    for packet in seen:
        proto = protocol(packet["line"])
        by_destination["%s %s:%s" % (proto, packet["dst"], endpoint_port(packet["line"]))] += 1
        owners["proc %s / eproc %s" % (packet["proc"][0] if packet["proc"] else "-",
                                        packet["eproc"][0] if packet["eproc"] else "-")] += 1
    return {
        "packets": len(seen), "udp": len(udp), "stun": len(stun), "dns": len(dns),
        "dnsQuestions": questions,
        "destinations": by_destination.most_common(12),
        "senders": owners.most_common(8),
        "stunSenders": sorted({(p["proc"][0] if p["proc"] else "-", p["proc"][1] if p["proc"] else 0,
                                p["eproc"][0] if p["eproc"] else "-", p["eproc"][1] if p["eproc"] else 0)
                               for p in stun}),
    }


def proxy_log(proxy):
    if proxy is None:
        return None
    commands = collections.Counter(request["command"] for request in proxy.requests)
    return {"commands": dict(commands), "udpDatagrams": proxy.udp_datagrams}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    app = os.path.abspath(args.app)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    capture_path = os.path.join(out, "capture.txt")
    capture = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "INP", "-n", "-tt", "-l",
                                "not host 127.0.0.1 and not host ::1"],
                               stdout=open(capture_path, "w"), stderr=open(os.path.join(out, "tcpdump.err"), "w"))
    time.sleep(3)

    http, socks, socks_udp, socks_default, http_default, socks_relay = (
        leak_check.ForwardingProxy(), leak_check.ForwardingProxy(), leak_check.ForwardingProxy(udp=True),
        leak_check.ForwardingProxy(udp=True), leak_check.ForwardingProxy(), leak_check.ForwardingProxy(udp=True))

    def proxy(kind, forwarding):
        port = forwarding.http_port if kind == "httpConnect" else forwarding.socks_port
        return {"kind": kind, "host": "127.0.0.1", "port": port}

    scenarios = [
        ("direct", {"webRTC": "unrestricted"}, None),
        ("http", {"webRTC": "unrestricted", "proxy": proxy("httpConnect", http)}, http),
        ("http-default", {"proxy": proxy("httpConnect", http_default)}, http_default),
        ("socks", {"webRTC": "unrestricted", "proxy": proxy("socks5", socks)}, socks),
        ("socks-udp", {"webRTC": "unrestricted", "proxy": proxy("socks5", socks_udp)}, socks_udp),
        ("socks-default", {"proxy": proxy("socks5", socks_default)}, socks_default),
        ("socks-relay", {"webRTC": "unrestricted", "relay": "harness", "proxy": proxy("socks5", socks_relay)},
         socks_relay),
    ]
    windows = {}
    report = {"scenarios": {}}
    for name, settings, forwarding in scenarios:
        profile = dict(settings, name=name)
        begin = time.time()
        process = start(app, out, name, [profile])
        try:
            process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            process.kill()
        windows[name] = (begin, time.time() + 2)
        report["scenarios"][name] = {"settings": {k: v for k, v in settings.items() if k != "proxy"},
                                     "proxyKind": settings.get("proxy", {}).get("kind"),
                                     "exit": process.returncode, "page": page_results(out, name, name),
                                     "proxy": proxy_log(forwarding)}
        print("ran %s: exit %s" % (name, process.returncode), flush=True)
        time.sleep(4)

    # Two app processes at once, a direct profile each: whose STUN packets are whose?
    begin = time.time()
    pair = [start(app, out, "two-direct-%d" % index, [{"name": "two-direct-%d" % index, "webRTC": "unrestricted"}])
            for index in (1, 2)]
    for process in pair:
        try:
            process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            process.kill()
    windows["two-direct"] = (begin, time.time() + 2)
    report["twoDirect"] = {"appPIDs": [process.pid for process in pair],
                           "pages": [page_results(out, "two-direct-%d" % i, "two-direct-%d" % i) for i in (1, 2)]}

    time.sleep(3)
    subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], capture_output=True)
    time.sleep(2)
    with open(capture_path, encoding="utf-8", errors="replace") as handle:
        packets = [egress_check.parse(line) for line in handle]
    report["capture"] = {"lines": len(packets), "withProcess": sum(1 for p in packets if p["proc"])}

    for name, (begin, end) in windows.items():
        seen = wire(packets, begin, end)
        if name == "two-direct":
            report["twoDirect"]["wire"] = seen
            pids = set(report["twoDirect"]["appPIDs"])
            report["twoDirect"]["stunActedForAppPIDs"] = sorted({s[3] for s in seen["stunSenders"]} & pids)
            report["twoDirect"]["stunSentByPIDs"] = sorted({s[1] for s in seen["stunSenders"]})
        else:
            report["scenarios"][name]["wire"] = seen

    with open(os.path.join(out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=2, default=str)

    lines = ["## A profile's WebRTC on the wire (pktap; the proxies on this Mac, loopback not captured)", "",
             "capture: %(lines)d lines, %(withProcess)d with their process" % report["capture"], "",
             "| scenario | proxy | WebRTC stored | page: RTCPeerConnection, candidates | proxy was asked | "
             "the app's packets outside the Mac: all / UDP / STUN / DNS | DNS asked for it | UDP around the proxy |",
             "|---|---|---|---|---|---|---|---|"]
    for name, data in report["scenarios"].items():
        page = (data["page"] or {}).get("webrtc") or {}
        candidates = "n/a" if not page else ("none (WebRTC off)" if page.get("available") is False else
                                             "%s; srflx %s, host %s, relay %s, relay at proxy %s"
                                             % (page.get("candidates"), page.get("srflx"), page.get("host"),
                                                page.get("relay"), page.get("relayIsProxyAddress")))
        seen = data.get("wire", {})
        around = ("n/a (no proxy: the control)" if not data["proxyKind"] else
                  ("YES" if (seen.get("udp") or 0) - (seen.get("dns") or 0) > 0 else "no"))
        data["udpAroundProxy"] = around
        lines.append("| %s | %s | %s | %s | %s | %s / %s / %s / %s | %s | %s |" % (
            name, data["proxyKind"] or "none", data["settings"].get("webRTC", "default"), candidates,
            (data["proxy"] or {}).get("commands", "-"), seen.get("packets"), seen.get("udp"), seen.get("stun"),
            seen.get("dns"), ", ".join(seen.get("dnsQuestions", [])[:6]) or "-", around))
    two = report["twoDirect"]
    lines += ["", "**Two app processes at once** (app PIDs %s): STUN packets sent by %s; acted for app PIDs %s; "
              "senders %s" % (two["appPIDs"], two.get("stunSentByPIDs"), two.get("stunActedForAppPIDs"),
                              two.get("wire", {}).get("stunSenders"))]
    for name, data in report["scenarios"].items():
        lines.append("")
        lines.append("<details><summary>%s: destinations and senders</summary>\n\n%s\n\n%s\n</details>" % (
            name, data.get("wire", {}).get("destinations"), data.get("wire", {}).get("senders")))
    text = "\n".join(lines)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(text + "\n")
    measured = report["capture"]["withProcess"] > 0 and any(d["page"] for d in report["scenarios"].values())
    if not measured:
        print("::error::nothing measured: no packet with its process, or no page result")
    return 0 if measured else 1


if __name__ == "__main__":
    sys.exit(main())
