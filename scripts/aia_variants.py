#!/usr/bin/env python3
"""Which of WebKit's behaviors that follow an app's SDK makes this Mac resolve a certificate's AIA
address outside a profile's proxy?

    python3 scripts/aia_variants.py --app build/unsandboxed/PrivacyBrowser.app --sdk "26.5,$(xcrun --show-sdk-version)" \\
        --out build/aia-variants --title "AIA variants"

CI run 448 (macOS 27): with every one of those behaviors on (+[WKProcessPool
_setLinkedOnOrAfterEverything], SDKBehaviors.swift), the self-test's certificate check had the AIA
canary — `pbaiacanary.leak.example.com`, the address the self-test proxy's certificate names for its
missing intermediate — resolved by this Mac, outside the profile's proxy. An executable that declares
a newer SDK gets some of the same behaviors (WebKit's network loader among them), so that decides
whether one can be used. This runs the self-test's "certificates" group alone (PB_SELFTEST_ONLY) under
a packet capture with process names, three times, each in a window of its own:

  * the app as built: WebKit's behaviors as the SDK its executable declares gives them;
  * the same with every behavior on (--sdk-everything);
  * a copy whose executable declares each SDK given (vtool; signed ad hoc with the app's entitlements)
    — on macOS 27, 26.5 as well as 27: a build made with Xcode 26 declares 26.5 and runs there too.

and counts, per window, the DNS questions for `pbaiacanary` (a fetch made by this Mac for a profile
with a proxy) and for the control `pbaiacontrol` (a profile without a proxy, which the system is
expected to fetch for: the capture sees such packets). A measurement: exit 0 always.
"""
import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = "Contents/MacOS/PrivacyBrowser"
PORTS = {"http": 18180, "socks": 18181, "tls-control": 18186, "canary": 18187}
LINE = re.compile(r"^(\d+\.\d+) \(([^)]*)\)")


def notice(title, text):
    print(f"::notice title={title}::{text[:900]}", flush=True)


def wait_for_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.5)
    return False


def declared_sdk(binary):
    shown = subprocess.run(["xcrun", "vtool", "-show-build", binary], capture_output=True, text=True).stdout
    values = dict(re.findall(r"^\s*(minos|sdk)\s+(\S+)", shown, re.M))
    return values.get("minos"), values.get("sdk")


def copy_declaring(app, sdk, scratch, out):
    """A copy of `app` whose executable declares `sdk`, or None."""
    copy = os.path.join(scratch, "PrivacyBrowser.app")
    shutil.copytree(app, copy, symlinks=True)
    binary = os.path.join(copy, BINARY)
    minos, _ = declared_sdk(binary)
    if not minos:
        return None
    done = subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", minos, sdk, "-replace",
                           "-output", binary + ".declared", binary], capture_output=True, text=True)
    if done.returncode != 0:
        print(f"vtool: {done.stderr.strip()}", flush=True)
        return None
    os.replace(binary + ".declared", binary)
    entitlements = os.path.join(out, "entitlements.plist")
    with open(entitlements, "wb") as handle:
        handle.write(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", app], capture_output=True).stdout)
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--entitlements", entitlements,
                    "--sign", "-", copy], capture_output=True)
    return copy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--sdk", required=True, help="the SDKs the copies declare, comma-separated")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default="AIA variants")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    out = os.path.abspath(args.out)

    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "selftest_proxy.py"),
                              "--http", str(PORTS["http"]), "--socks", str(PORTS["socks"]),
                              "--tls-control", str(PORTS["tls-control"]),
                              "--canary", str(PORTS["canary"])],
                             stdout=open(os.path.join(out, "proxy.txt"), "w"), stderr=subprocess.STDOUT)
    if not wait_for_port(PORTS["http"]):
        print(f"::warning title={args.title}::the self-test proxy did not start", flush=True)
        proxy.kill()
        return 0
    capture_path = os.path.join(out, "capture.txt")
    capture = subprocess.Popen(["sudo", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                "not host 127.0.0.1 and not host ::1"],
                               stdout=open(capture_path, "w"), stderr=open(os.path.join(out, "tcpdump.err"), "w"))
    time.sleep(2)

    scratch = tempfile.mkdtemp(prefix="pb-aia-variants-")
    variants = [("as built", args.app, [])]
    variants.append(("as built, every behavior on", args.app, ["--sdk-everything"]))
    for sdk in [value.strip() for value in args.sdk.split(",") if value.strip()]:
        folder = os.path.join(scratch, sdk)
        os.makedirs(folder)
        copy = copy_declaring(args.app, sdk, folder, out)
        if copy:
            variants.append((f"declaring SDK {sdk}", copy, []))
        else:
            print(f"::warning title={args.title}::no copy declaring SDK {sdk}", flush=True)

    environment = dict(os.environ, PB_SELFTEST_ONLY="certificates",
                       PB_SELFTEST_HTTP_PROXY_PORT=str(PORTS["http"]),
                       PB_SELFTEST_TLS_CONTROL_PORT=str(PORTS["tls-control"]),
                       PB_SELFTEST_CANARY_PORT=str(PORTS["canary"]))
    windows = []
    for index, (name, app, extra) in enumerate(variants):
        log = os.path.join(out, f"variant-{index}.txt")
        begin = time.time()
        try:
            result = subprocess.run([os.path.join(app, BINARY), "--self-test", *extra], env=environment,
                                    capture_output=True, text=True, timeout=240)
            output = result.stdout
        except subprocess.TimeoutExpired as expired:
            output = (expired.stdout or b"").decode(errors="replace") + "\n(timed out)"
        # A question can follow the check by a moment: the window closes a little after it.
        time.sleep(4)
        end = time.time()
        with open(log, "w") as handle:
            handle.write(output)
        windows.append((name, app, begin, end, output))
        time.sleep(2)

    subprocess.run(["sudo", "pkill", "-INT", "-f", "tcpdump -i pktap"], capture_output=True)
    time.sleep(2)
    proxy.kill()
    shutil.rmtree(scratch, ignore_errors=True)

    with open(capture_path, errors="replace") as handle:
        lines = handle.read().splitlines()
    for name, app, begin, end, output in windows:
        minos, sdk = declared_sdk(os.path.join(app, BINARY)) if os.path.exists(os.path.join(app, BINARY)) else (None, None)
        counts = {"pbaiacanary": [], "pbaiacontrol": []}
        for line in lines:
            match = LINE.match(line)
            if not match or not begin <= float(match.group(1)) <= end:
                continue
            for name_part in counts:
                if f"{name_part}.leak.example.com" in line and "?" in line:
                    counts[name_part].append(match.group(2))
        verdicts = [l for l in output.splitlines() if l.startswith(("PASS certificates", "FAIL certificates", "SELFTEST", "INFO WebKit's behaviors"))]
        canary = counts["pbaiacanary"]
        summary = (f"AIA-VARIANT {name} (declares minos {minos}, sdk {sdk}): the canary asked of this Mac's resolver "
                   f"{len(canary)} time(s){' — by ' + '; '.join(sorted(set(canary))) if canary else ''}; "
                   f"the control {len(counts['pbaiacontrol'])} time(s)")
        print(summary, flush=True)
        for verdict in verdicts:
            print("    " + verdict, flush=True)
        notice(args.title, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
