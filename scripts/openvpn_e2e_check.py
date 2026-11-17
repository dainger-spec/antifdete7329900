#!/usr/bin/env python3
"""The checks of scripts/openvpn_macos_e2e.sh (docs/OPENVPN.md), one mode per step.

    openvpn_e2e_check.py refused <webdriver address>
    openvpn_e2e_check.py pages   <webdriver address> <session file>
    openvpn_e2e_check.py closed  <webdriver address> <session file>
    openvpn_e2e_check.py capture <capture.txt> <server address>

`refused`: a new session must not start the profile, and say that the VPN server refused the user
name or password. `pages`: a session (kept in the session file) loads http://vpn-only.test:8080/ —
a name only the tunnel's DNS server knows — and http://10.8.0.1:8080/, and the server must see both
come from the client's tunnel address 10.8.0.2. `closed`: with the server killed, a page asked now
must not load. `capture`: a pktap capture (`tcpdump -i pktap,all -k NP -n -tt`, loopback left out)
must show no packet of the profile's process, made for it, or of the confined OpenVPN client and
LumenTunnel; no DNS question for vpn-only.test outside the tunnel; and its controls must be in it:
the forwarder's packets (the app's) to the server, and the question inside the tunnel.

Each prints `OPENVPN PASS …` or `OPENVPN FAIL …` and exits 0 or 1.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request

TUNNEL_ADDRESS = "10.8.0.2"
SERVER_TUNNEL_ADDRESS = "10.8.0.1"


def call(method, url, body=None, timeout=120):
    data = None if body is None and method != "POST" else json.dumps(body or {}).encode()
    request = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)["value"]
    except urllib.error.HTTPError as error:
        value = json.load(error).get("value", {})
        raise RuntimeError(f"{value.get('error')}: {value.get('message')}") from None


def new_session(address):
    return call("POST", address.rstrip("/") + "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}}, timeout=200)["sessionId"]


def page_text(address, session, url):
    base = f"{address.rstrip('/')}/session/{session}"
    call("POST", base + "/url", {"url": url}, timeout=90)
    return call("POST", base + "/execute/sync", {"script": "return document.body ? document.body.innerText : ''", "args": []})


def done(ok, line):
    print(("OPENVPN PASS " if ok else "OPENVPN FAIL ") + line, flush=True)
    sys.exit(0 if ok else 1)


def refused(address):
    try:
        session = new_session(address)
    except RuntimeError as error:
        text = str(error)
        done("refused the user name or password" in text,
             f"a wrong password: the profile did not start, and was said why ({text[:300]})")
    done(False, f"a wrong password: a session started ({session})")


def pages(address, session_file):
    session = new_session(address)
    with open(session_file, "w") as handle:
        handle.write(session)
    seen = []
    for url in ("http://vpn-only.test:8080/", f"http://{SERVER_TUNNEL_ADDRESS}:8080/by-address"):
        try:
            text = page_text(address, session, url).strip()
        except RuntimeError as error:
            done(False, f"{url} did not load: {error}")
        seen.append(f"{url} → {text}")
        if text != f"seen-from={TUNNEL_ADDRESS}":
            done(False, f"{url} was seen from elsewhere than the tunnel: {text!r}")
    done(True, "pages through the tunnel: " + "; ".join(seen))


def closed(address, session_file):
    session = open(session_file).read().strip()
    # A few seconds for OpenVPN to notice nothing answers is not needed: nothing must load at all,
    # whether the tunnel is still thought up or already down.
    time.sleep(3)
    try:
        text = page_text(address, session, f"http://{SERVER_TUNNEL_ADDRESS}:8080/after-the-server-is-gone").strip()
    except RuntimeError as error:
        done(True, f"the server gone: the page did not load ({str(error)[:200]})")
    done("seen-from" not in text, f"the server gone: the page shows {text[:200]!r}")


QUESTION = re.compile(r"\b(?:A|AAAA|HTTPS|SVCB|ANY)(?: \(Q[MU]\))?\? (\S+?)\.? ")
PROC = re.compile(r"(?<![e])proc ([^,():]+):(\d+)")
EPROC = re.compile(r"eproc ([^,():]+):(\d+)")
FLOW = re.compile(r"\bIP6? (\S+) > (\S+?):? ")


def capture(path, server_address):
    lines = open(path, errors="replace").read().splitlines()
    if not lines:
        done(False, "the capture is empty")
    leaks, forwarder, inside_question = [], 0, 0
    for line in lines:
        proc, eproc = PROC.search(line), EPROC.search(line)
        names = [m.group(1) for m in (proc, eproc) if m]
        flow = FLOW.search(line)
        source, destination = (flow.group(1), flow.group(2)) if flow else ("", "")
        # Whatever a profile's process sent, or WebKit's processes sent for it, outside loopback.
        if any(name.startswith("LumenProfile") for name in names):
            leaks.append("the profile's process: " + line)
        # The confined client and its tun: nothing but loopback, which this capture leaves out.
        if any(name.startswith("LumenTunnel") for name in names):
            leaks.append("LumenTunnel: " + line)
        # The forwarder: the app's own process, to the server's address and port — the control.
        if any(name == "Lumen" for name in names) and (destination.startswith(server_address + ".1194")):
            forwarder += 1
        question = QUESTION.search(line)
        if question and "vpn-only" in question.group(1):
            if source.startswith(TUNNEL_ADDRESS + ".") and destination.startswith(SERVER_TUNNEL_ADDRESS + ".53"):
                inside_question += 1
            elif not (source.startswith(SERVER_TUNNEL_ADDRESS + ".53") and destination.startswith(TUNNEL_ADDRESS + ".")):
                leaks.append("a question for the tunnel's name outside it: " + line)
    # The client's own openvpn is not told apart by name from the server's (both "openvpn"): its
    # packets to the server go through the forwarder on loopback, which the capture leaves out, so
    # an openvpn packet to the server from anywhere but the server itself is the client's.
    for line in lines:
        flow = FLOW.search(line)
        if flow and "openvpn" in line and flow.group(2).startswith(server_address + ".1194"):
            leaks.append("an openvpn process reached the server around the forwarder: " + line)
    if leaks:
        for leak in leaks[:20]:
            print("  " + leak[:400])
        done(False, f"{len(leaks)} packet(s) around the tunnel")
    if forwarder == 0:
        done(False, "the capture shows no packet of the app's forwarder to the server: it sees nothing it should (its control)")
    if inside_question == 0:
        done(False, "the capture shows no DNS question inside the tunnel: it sees nothing it should (its control)")
    done(True, f"the capture ({len(lines)} packets outside loopback): nothing of the profile's process, of LumenTunnel or of "
               f"the client's openvpn around the tunnel; {forwarder} packets of the forwarder to the server and "
               f"{inside_question} questions inside the tunnel seen (the controls)")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(64)
    mode = sys.argv[1]
    if mode == "refused":
        refused(sys.argv[2])
    elif mode == "pages":
        pages(sys.argv[2], sys.argv[3])
    elif mode == "closed":
        closed(sys.argv[2], sys.argv[3])
    elif mode == "capture":
        capture(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(64)


if __name__ == "__main__":
    main()
