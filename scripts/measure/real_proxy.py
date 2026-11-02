#!/usr/bin/env python3
"""Measurement only (never merged): a profile behind one of the owner's real proxies, where the
earlier reports had to say "the proxy was a local one".

    PB_TEST_PROXIES="host:port:login:password\n…" python3 scripts/measure/real_proxy.py \
        --app build/unsandboxed/Lumen.app --out build/real-proxy --pubkey scripts/measure/report_key.pub [--index 1]

1. Where the proxy leaves from: its TCP exit as the app finds it (Cloudflare's trace at 1.1.1.1
   through it) and this runner's own address (asked directly) — what the pages below must and must
   not show.
2. "What sites see" (`Lumen --what-sites-see-check --safari-window`), the profile behind the proxy:
   its own process, Safari's window, its language and time zone from the proxy's location.
3. Live services (`Lumen --capture-sites`, SiteCapture.swift) in two profiles behind the proxy:
   WebRTC through the app's relay (only when the proxy's UDP leaves from its TCP exit — the gate's
   own check — else the capture says why), and WebRTC off as a customer has it without the network
   guard. Each page's text and a screenshot.
4. Every packet of this Mac meanwhile (pktap): where the app's own and WebKit's packets went — the
   proxy's address, its UDP relay, anything else.

The repository is public: the summary (stdout, the job's summary, summary.md) names no address and
no login — addresses masked to their first two octets, and whether a page showed the proxy's exit
or this runner's own address said as yes/no. Everything else (texts, screenshots, the app's output)
is kept only encrypted to the public key given (report.tar.enc, key.enc); the private half is not in
the repository.
"""
import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import egress_check  # noqa: E402
import proxy_udp  # noqa: E402

LIVE_SITES = [
    ("browserleaks-ip", "https://browserleaks.com/ip", 12000),
    ("browserleaks-webrtc", "https://browserleaks.com/webrtc", 12000),
    ("browserleaks-dns", "https://browserleaks.com/dns", 15000),
    ("ipleak", "https://ipleak.net/", 20000),
    ("browserscan", "https://www.browserscan.net/", 20000),
    ("pixelscan", "https://pixelscan.net/", 25000),
    ("whoer", "https://whoer.net/", 20000),
]

# A live service: wait as a person would, then keep its text.
LIVE = r"""
await new Promise((r) => setTimeout(r, 1500));
const text = (document.body && document.body.innerText) || '';
return { title: document.title, url: location.href, length: text.length, text: text.slice(0, 60000) };
"""

IPV4 = re.compile(r"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b")
IPV6 = re.compile(r"(?<![\w:])(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?![\w:])")
KEYWORDS = re.compile(r"proxy|vpn|tor\b|leak|webrtc|dns|time ?zone|timezone|language|anonym|masking|detected|"
                      r"hosting|datacenter|data center|residential|isp|score|trust|consisten|mismatch|real ip", re.I)


class Masker:
    """Every address cut to its first two octets, the proxy's login and password replaced."""

    def __init__(self, secrets):
        self.secrets = [s for s in secrets if s]

    def __call__(self, text):
        text = str(text)
        for secret in self.secrets:
            text = text.replace(secret, "***")
        text = IPV4.sub(lambda m: f"{m.group(1)}.{m.group(2)}.x.x", text)
        return IPV6.sub("v6addr", text)


def own_address():
    """This runner's own IPv4 address, asked directly (not through any proxy)."""
    for url in ("https://api.ipify.org", "https://checkip.amazonaws.com"):
        try:
            with urllib.request.urlopen(url, timeout=10) as answer:
                return str(ipaddress.ip_address(answer.read().decode().strip()))
        except Exception:
            continue
    return None


def run(command, env=None, timeout=900):
    """A command's exit code and its whole output (kept for the encrypted report only)."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env)
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        return None, out + "\nTIMEOUT"


class Capture:
    """Every packet leaving or entering this Mac, with the process it is for (pktap)."""

    def __init__(self, path):
        self.path = path
        self.process = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                         "not host 127.0.0.1 and not host ::1"],
                                        stdout=open(path, "w"), stderr=open(path + ".err", "w"))
        time.sleep(3)

    def stop(self):
        time.sleep(2)
        subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], capture_output=True)
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()

    def packets(self):
        with open(self.path, encoding="utf-8", errors="replace") as handle:
            return [egress_check.parse(line) for line in handle]


def app_destinations(packets, pids, proxy_ip, relay_ip):
    """Where the app's processes (and WebKit's, counted for them) sent packets: the proxy's address,
    its UDP relay, or anything else."""
    kinds = {"proxy": 0, "relay": 0, "other": 0}
    others = {}  # "address:port" → packets
    for packet in packets:
        who = [p for p in (packet["proc"], packet["eproc"]) if p]
        if not any(pid in pids or name.startswith("Lumen") for name, pid in who):
            continue
        destination = packet["dst"]
        if destination is None or packet["src"] is None:
            continue
        # Only what the Mac sent: a packet from the proxy to this Mac is the answer.
        if str(packet["src"]) in (proxy_ip, relay_ip):
            continue
        target = str(destination)
        if target == proxy_ip:
            kinds["proxy"] += 1
        elif relay_ip and target == relay_ip:
            kinds["relay"] += 1
        else:
            kinds["other"] += 1
            key = f"{target}:{packet['dst_port']}"
            others[key] = others.get(key, 0) + 1
    return kinds, others


def what_sites_see(app, line, out, mask):
    binary = os.path.join(app, "Contents", "MacOS", "Lumen")
    env = dict(os.environ, PB_MEASURE_PROXY=line)
    code, output = run([binary, "--what-sites-see-check", "--safari-window", "--proxy-from-environment"], env=env, timeout=420)
    with open(os.path.join(out, "what-sites-see.txt"), "w") as handle:
        handle.write(output)
    lines = [mask(l) for l in output.splitlines() if l.startswith("WHAT-SITES-SEE")]
    return code, lines


def live(app, proxy, out, mask):
    spec = {
        "window": {"width": 1000, "height": 700},
        # WebRTC off first: a relay the gate refuses ("no relay for this proxy: …") ends the capture.
        "profiles": [
            {"name": "real-off",
             "proxy": {"kind": "socks5", "host": proxy["host"], "port": proxy["port"],
                       "username": proxy["login"], "password": proxy["password"]}},
            {"name": "real-relay", "webRTC": "unrestricted", "relay": "harness",
             "proxy": {"kind": "socks5", "host": proxy["host"], "port": proxy["port"],
                       "username": proxy["login"], "password": proxy["password"]}},
        ],
        "pages": [{"name": name, "url": url, "script": LIVE, "settleMs": settle, "timeoutMs": 60000, "screenshot": True}
                  for name, url, settle in LIVE_SITES],
    }
    descriptor, spec_path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(descriptor, "w") as handle:
        json.dump(spec, handle)
    binary = os.path.join(app, "Contents", "MacOS", "Lumen")
    process = subprocess.Popen([binary, "--capture-sites", spec_path, out], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True)
    pids = {process.pid}
    try:
        output, _ = process.communicate(timeout=1500)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate()
        output += "\nTIMEOUT"
    os.remove(spec_path)
    with open(os.path.join(out, "capture-sites.txt"), "w") as handle:
        handle.write(output)
    results = {}
    for profile in spec["profiles"]:
        path = os.path.join(out, profile["name"] + ".json")
        if os.path.exists(path):
            with open(path) as handle:
                results[profile["name"]] = json.load(handle)
        else:
            results[profile["name"]] = None
    failures = [mask(l) for l in output.splitlines() if "failed" in l or "Failure" in l or "no relay" in l or "TIMEOUT" in l]
    return results, failures, pids


def read_page(result, exit_ip, own_ip, mask):
    """What a page showed, said without addresses."""
    if not isinstance(result, dict) or "text" not in result:
        return {"loaded": False, "error": mask(result.get("error", "")) if isinstance(result, dict) else "no result"}
    text = result.get("text") or ""
    addresses = set(IPV4.findall(text))
    addresses = {".".join(a) for a in addresses}
    lines = [mask(l.strip())[:160] for l in text.splitlines() if l.strip() and KEYWORDS.search(l)][:25]
    return {"loaded": True, "title": mask(result.get("title", ""))[:80], "length": len(text),
            "showsProxyExit": bool(exit_ip and exit_ip in addresses),
            "showsRunnersOwnAddress": bool(own_ip and own_ip in addresses),
            "otherAddresses": len(addresses - {exit_ip, own_ip}),
            "lines": lines}


def encrypt_directory(directory, pubkey, out):
    """report.tar.enc (AES-256-CBC, PBKDF2) and key.enc (its key, RSA-OAEP): only the private key opens them."""
    tar_path = os.path.join(out, "report.tar")
    key_path = os.path.join(out, "key.hex")
    try:
        with tarfile.open(tar_path, "w") as tar:
            tar.add(directory, arcname="report")
        with open(key_path, "w") as handle:
            handle.write(os.urandom(32).hex())
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-in", tar_path, "-out", tar_path + ".enc",
                        "-pass", f"file:{key_path}"], check=True)
        subprocess.run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", pubkey, "-pkeyopt", "rsa_padding_mode:oaep",
                        "-in", key_path, "-out", os.path.join(out, "key.enc")], check=True)
        print("the full report is in report.tar.enc (key.enc), for the private key only")
    except Exception as error:
        print(f"the full report could not be encrypted ({error}): not kept")
        for leftover in (tar_path + ".enc", os.path.join(out, "key.enc")):
            if os.path.exists(leftover):
                os.remove(leftover)
    finally:
        for secret in (tar_path, key_path):
            if os.path.exists(secret):
                os.remove(secret)
        shutil.rmtree(directory, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pubkey", required=True)
    parser.add_argument("--index", type=int, default=1, help="which proxy of PB_TEST_PROXIES (1-based)")
    args = parser.parse_args()
    lines = [l.strip() for l in (os.environ.get("PB_TEST_PROXIES") or "").splitlines() if l.strip()]
    if len(lines) < args.index:
        print("REAL-PROXY SKIPPED: no PB_TEST_PROXIES (a repository secret, host:port:login:password per line)")
        return 0
    line = lines[args.index - 1]
    host, port, login, password = line.split(":", 3)
    proxy = {"host": host, "port": int(port), "login": login, "password": password}
    mask = Masker([login, password])
    os.makedirs(args.out, exist_ok=True)
    plain = os.path.join(args.out, "plain")
    os.makedirs(plain, exist_ok=True)
    summary = [f"### A profile behind a real proxy (#{args.index}, {mask(host)})", ""]

    own_ip = own_address()
    exit_ip = None
    for address in proxy_udp.TRACE_ADDRESSES:
        try:
            exit_ip = proxy_udp.trace_exit(proxy, address)
            break
        except Exception as error:
            summary.append(f"- the trace at {address} through the proxy: {mask(error)}")
    try:
        association = proxy_udp.Association(proxy)
        relay_ip = association.relay[0]
        association.close()
    except Exception as error:
        relay_ip = None
        summary.append(f"- UDP ASSOCIATE: {mask(error)}")
    summary.append(f"- the proxy's TCP exit (Cloudflare's trace): {'found' if exit_ip else 'NOT found'}; "
                   f"this runner's own address: {'found' if own_ip else 'NOT found'}; "
                   f"exit = entry: {proxy_udp.relation(exit_ip, host)}; UDP relay = entry: {proxy_udp.relation(relay_ip, host)}")

    code, wss = what_sites_see(args.app, line, plain, mask)
    summary += ["", f"#### What sites see, the profile behind the proxy in Safari's window (exit {code})", ""]
    summary += [f"    {l[:400]}" for l in wss[:40]]

    capture = Capture(os.path.join(plain, "capture.txt"))
    started = time.time()
    results, failures, pids = live(args.app, proxy, plain, mask)
    capture.stop()
    summary += ["", f"#### Live services ({int(time.time() - started)} s)", ""]
    for failure in failures[:20]:
        summary.append(f"- {failure[:300]}")
    summary += ["", "| profile | page | loaded | shows the proxy's exit | shows this runner's own address | other addresses |",
                "|---|---|---|---|---|---|"]
    details = []
    for profile, pages in results.items():
        if pages is None:
            summary.append(f"| {profile} | — | NO RESULT | | | |")
            continue
        for name, _, _ in LIVE_SITES:
            page = read_page(pages.get(name), exit_ip, own_ip, mask)
            summary.append(f"| {profile} | {name} | {'yes' if page['loaded'] else 'NO: ' + page.get('error', '')[:80]} | "
                           f"{page.get('showsProxyExit', '—')} | {page.get('showsRunnersOwnAddress', '—')} | {page.get('otherAddresses', '—')} |")
            if page["loaded"]:
                details.append((profile, name, page["lines"]))
    try:
        packets = capture.packets()
        kinds, others = app_destinations(packets, pids, host, relay_ip)
        summary += ["", f"#### Where the app's packets went while the live services loaded (pktap, {len(packets)} packets)", "",
                    f"- to the proxy's address: {kinds['proxy']}; to its UDP relay: {kinds['relay']}; anywhere else: {kinds['other']}"]
        for target, count in sorted(others.items(), key=lambda item: -item[1])[:15]:
            summary.append(f"  - {mask(target)}: {count}")
    except Exception as error:
        summary.append(f"- the capture could not be read: {error}")
    summary += ["", "#### What the services say (their lines about proxies, leaks, WebRTC, DNS, time zone; addresses masked)", ""]
    for profile, name, page_lines in details:
        summary.append(f"<details><summary>{profile} — {name}</summary>\n\n```\n" + "\n".join(page_lines) + "\n```\n</details>")
    text = "\n".join(summary) + "\n"
    print(text)
    with open(os.path.join(args.out, "summary.md"), "w") as handle:
        handle.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(text)
    with open(os.path.join(plain, "facts.json"), "w") as handle:
        json.dump({"exitIP": exit_ip, "ownIP": own_ip, "relayIP": relay_ip, "entry": host}, handle)
    encrypt_directory(plain, args.pubkey, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
